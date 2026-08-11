#!/bin/bash -e
#
# One command to regression-test the fork's mpv patches on the host:
#
#     buildscripts/tests/run.sh
#
# It builds a NATIVE libmpv from the same patched sources the Android build
# uses, then runs tests/prefetch_hook_test.c against it. No device, no
# emulator, no network beyond the mpv checkout; about 15 s once libmpv is built.
#
# Why a native build and not the shipped .so: the patches under patches/mpv are
# plain C in mpv's core, so they are testable anywhere mpv builds. Testing them
# on the host is the only way this repo gets a regression test at all — an
# Android .so can only be exercised on a device, which is exactly the loop that
# does not run on every change.
#
# The Android build is untouched by this script: it only adds
# deps/mpv/_build-linux (meson writes a .gitignore inside its own build
# directories, which is also why patch.sh's `git clean -fd` leaves them alone).
#
# Host requirements: a C compiler, meson >= 1.3 (mpv 0.41's floor), ninja,
# pkg-config, and dev packages for ffmpeg (libavcodec/libavformat/libavutil/
# libswresample/libswscale) and libplacebo >= 6.338. Note libplacebo is not
# optional for mpv >= 0.37 — see scripts/mpv.sh.

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. ./include/depinfo.sh

BUILD=deps/mpv/_build-linux
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

if [ ! -d deps/mpv ]; then
    echo "==> cloning mpv $v_mpv"
    mkdir -p deps
    git clone --depth 1 --branch v$v_mpv https://github.com/mpv-player/mpv.git deps/mpv
fi

# Always re-apply from pristine, so the test can never pass against a tree
# somebody edited by hand.
echo "==> applying patches"
./patch.sh

echo "==> building native libmpv"
# Mirrors scripts/mpv.sh's feature set as closely as a host build can, minus the
# cross file and the Android AO, so what is tested is the configuration we ship.
if [ ! -f $BUILD/build.ninja ]; then
    # Both directories, in that order: we are not standing in mpv's source
    # tree, and with a single argument meson would read it as the SOURCE dir.
    meson setup $BUILD deps/mpv \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dgpl=false \
        -Dlua=disabled \
        -Diconv=disabled \
        -Dvulkan=disabled \
        -Dgl=disabled \
        -Dplain-gl=disabled \
        -Dlibavdevice=disabled \
        -Djavascript=disabled \
        -Dlcms2=disabled \
        -Dlibarchive=disabled \
        -Dlibbluray=disabled \
        -Dzimg=disabled \
        -Djpeg=disabled \
        -Duchardet=disabled \
        -Drubberband=disabled \
        -Dvapoursynth=disabled \
        -Dcplugins=disabled \
        -Dzlib=disabled \
        -Dtests=false \
        -Dmanpage-build=disabled \
        -Dhtml-build=disabled \
        -Dpdf-build=disabled
fi
ninja -C $BUILD

echo "==> building the test"
LIB=$(ls $BUILD/libmpv.so* | head -1)
${CC:-cc} -O1 -Wall -Wextra -Wno-unused-parameter \
    -I deps/mpv/include \
    -o "$OUT/prefetch_hook_test" tests/prefetch_hook_test.c \
    -L "$PWD/$BUILD" -lmpv -lm -Wl,-rpath,"$PWD/$BUILD"

echo "==> running (libmpv: $(basename "$LIB"))"
"$OUT/prefetch_hook_test" "$OUT"
