#!/bin/bash

set -e

OPTIND=1

# Config

# For default registry and number of cores.
if [ ! -e config.sh ]; then
  echo "No config.sh, copying default values from config.sh.in."
  cp config.sh.in config.sh
fi
source ./config.sh

if [ -z "${BUILD_NAME}" ]; then
  export BUILD_NAME="custom_build"
fi

if [ -z "${NUM_CORES}" ]; then
  export NUM_CORES=16
fi

registry="${REGISTRY:-localhost}"
username=""
password=""
godot_version=""
git_treeish="master"
build_classical=1
build_mono=1
force_download=0
skip_download=1
skip_git_checkout=0
force_yes=0

while getopts "h?r:u:p:v:g:b:fscy" opt; do
  case "$opt" in
  h|\?)
    echo "Usage: $0 [OPTIONS...]"
    echo
    echo "  -r registry"
    echo "  -u username"
    echo "  -p password"
    echo "  -v godot version (e.g. 3.1-alpha5) [mandatory]"
    echo "  -g git treeish (e.g. master)"
    echo "  -b all|classical|mono (default: all)"
    echo "  -f force redownload of all images"
    echo "  -s skip downloading"
    echo "  -c skip checkout"
    echo "  -y yes"
    echo
    exit 1
    ;;
  r)
    registry=$OPTARG
    ;;
  u)
    username=$OPTARG
    ;;
  p)
    password=$OPTARG
    ;;
  v)
    godot_version=$OPTARG
    ;;
  g)
    git_treeish=$OPTARG
    ;;
  b)
    if [ "$OPTARG" == "classical" ]; then
      build_mono=0
    elif [ "$OPTARG" == "mono" ]; then
      build_classical=0
    fi
    ;;
  f)
    force_download=1
    ;;
  s)
    skip_download=1
    ;;
  c)
    skip_git_checkout=1
    ;;
  y)
    force_yes=1
    ;;
  esac
done

export podman=none
if which podman > /dev/null; then
  export podman=podman
elif which docker > /dev/null; then
  export podman=docker
fi

if [ "${podman}" == "none" ]; then
  echo "Either podman or docker needs to be installed"
  exit 1
fi

if [ $UID != 0 ]; then
  echo "WARNING: Running as non-root may cause problems for the uwp build"
fi

if [ -z "${godot_version}" ]; then
  echo "-v <version> is mandatory!"
  exit 1
fi

IFS=- read version status <<< "$godot_version"
echo "Building Godot '${version} ${status}' from commit or branch '${git_treeish}'."
if [ -q $force_yes 0 ]; then
  read -p "Is this correct (y/n)? " choice
  case "$choice" in
    y|Y ) echo "yes";;
    n|N ) echo "No, aborting."; exit 0;;
    * ) echo "Invalid choice, aborting."; exit 1;;
  esac
fi
export GODOT_VERSION_STATUS="${status}"

if [ ! -z "${username}" ] && [ ! -z "${password}" ]; then
  if ${podman} login ${registry} -u "${username}" -p "${password}"; then
    export logged_in=true
  fi
fi

if [ $skip_download == 0 ]; then
  echo "Fetching images"
  for image in windows linux web; do
    if [ ${force_download} == 1 ] || ! ${podman} image exists godot/$image; then
      if ! ${podman} pull ${registry}/godot/${image}; then
        echo "ERROR: image $image does not exist and can't be downloaded"
        exit 1
      fi
    fi
  done

  if [ ! -z "${logged_in}" ]; then
    echo "Fetching private images"

    for image in macosx android ios uwp; do
      if [ ${force_download} == 1 ] || ! ${podman} image exists godot-private/$image; then
        if ! ${podman} pull ${registry}/godot-private/${image}; then
          echo "ERROR: image $image does not exist and can't be downloaded"
          exit 1
        fi
      fi
    done
  fi
fi

# macOS and iOS need the Vulkan SDK
if [ ! -d "deps/vulkansdk-macos" ]; then
  echo "Missing Vulkan SDK for macOS, we're going to run into issues!"
fi

if [ "${skip_git_checkout}" == 0 ]; then
  git clone https://github.com/godotengine/godot git || /bin/true
  pushd git
  git checkout -b ${git_treeish} origin/${git_treeish} || git checkout ${git_treeish}
  git reset --hard
  git clean -fdx
  git pull origin ${git_treeish} || /bin/true

  # Validate version
  correct_version=$(python3 << EOF
import version;
if hasattr(version, "patch") and version.patch != 0:
  git_version = f"{version.major}.{version.minor}.{version.patch}"
else:
  git_version = f"{version.major}.{version.minor}"
print(git_version == "${version}")
EOF
  )
  if [[ "$correct_version" != "True" ]]; then
    echo "Version in version.py doesn't match the passed ${version}."
    exit 1
  fi

  sh misc/scripts/make_tarball.sh -v ${godot_version} -g ${git_treeish}
  popd
fi

export basedir="$(pwd)"
mkdir -p ${basedir}/out
mkdir -p ${basedir}/out/logs
mkdir -p ${basedir}/mono-glue

export podman_run="${podman} run --rm --env BUILD_NAME --env GODOT_VERSION_STATUS --env NUM_CORES --env CLASSICAL=${build_classical} --env MONO=${build_mono} -v ${basedir}/godot-${godot_version}.tar.gz:/root/godot.tar.gz -v ${basedir}/mono-glue:/root/mono-glue -w /root/"
export img_version=4.x-f36

mkdir -p ${basedir}/mono-glue
${podman_run} \
  -v ${basedir}/build-mono-glue:/root/build \
  ${registry}/godot-linux:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/mono-glue

mkdir -p ${basedir}/out/windows
${podman_run} \
  -v ${basedir}/build-windows:/root/build \
  -v ${basedir}/out/windows:/root/out \
  ${registry}/godot-windows:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/windows

mkdir -p ${basedir}/out/linux
${podman_run} \
  -v ${basedir}/build-linux:/root/build \
  -v ${basedir}/out/linux:/root/out \
  ${registry}/godot-linux:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/linux

mkdir -p ${basedir}/out/web
${podman_run} \
  -v ${basedir}/build-web:/root/build \
  -v ${basedir}/out/web:/root/out \
  ${registry}/godot-web:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/web

mkdir -p ${basedir}/out/macos
${podman_run} \
  -v ${basedir}/build-macos:/root/build \
  -v ${basedir}/out/macos:/root/out \
  -v ${basedir}/deps/vulkansdk-macos:/root/vulkansdk \
  ${registry}/godot-osx:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/macos

mkdir -p ${basedir}/out/android
${podman_run} \
  -v ${basedir}/build-android:/root/build \
  -v ${basedir}/out/android:/root/out \
  ${registry}/godot-android:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/android

mkdir -p ${basedir}/out/ios
${podman_run} \
  -v ${basedir}/build-ios:/root/build \
  -v ${basedir}/out/ios:/root/out \
  ${registry}/godot-ios:${img_version} \
  bash build/build.sh 2>&1 \
  | tee ${basedir}/out/logs/ios

#mkdir -p ${basedir}/out/uwp
#${podman_run} --ulimit nofile=32768:32768 -v ${basedir}/build-uwp:/root/build -v ${basedir}/out/uwp:/root/out ${registry}/godot-private/uwp:latest bash build/build.sh 2>&1 | tee ${basedir}/out/logs/uwp

if [ ! -z "$SUDO_UID" ]; then
  chown -R "${SUDO_UID}":"${SUDO_GID}" ${basedir}/git ${basedir}/out ${basedir}/mono-glue ${basedir}/godot*.tar.gz
fi
