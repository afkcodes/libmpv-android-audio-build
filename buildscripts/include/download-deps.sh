#!/bin/bash -e

. ./include/depinfo.sh

[ -z "$WGET" ] && WGET=wget

mkdir -p deps && cd deps

# mbedtls
[ ! -d mbedtls ] && git clone --depth 1 --branch v$v_mbedtls --recurse-submodules https://github.com/Mbed-TLS/mbedtls.git mbedtls

# libxml2
[ ! -d libxml2 ] && git clone --depth 1 --branch v$v_libxml2 --recursive https://gitlab.gnome.org/GNOME/libxml2.git libxml2

# ffmpeg
[ ! -d ffmpeg ] && git clone --depth 1 --branch n$v_ffmpeg https://github.com/FFmpeg/FFmpeg.git ffmpeg

# libplacebo — mandatory for mpv >= 0.37 (see depinfo.sh).
#
# --recursive is load-bearing: libplacebo keeps its build-time helpers
# (glad, fast_float, jinja, markupsafe, Vulkan-Headers) as submodules, and the
# crossfile sets wrap_mode = 'nodownload', so meson will NOT fetch them at
# configure time. Without them configure fails on the glad generator.
#
# github.com/haasn (libplacebo's own author) rather than the canonical
# code.videolan.org: the latter refuses connections from some networks
# ("Recv failure: Connection reset by peer", hit here on 2026-08-11), and a
# build that cannot fetch a mandatory dependency is not a build. Same tags,
# same history — it is upstream's own mirror.
[ ! -d libplacebo ] && git clone --depth 1 --branch v$v_libplacebo --recursive https://github.com/haasn/libplacebo.git libplacebo

# mpv
[ ! -d mpv ]  && git clone --depth 1 --branch v$v_mpv https://github.com/mpv-player/mpv.git mpv

# media-kit-android-helper
[ ! -d media-kit-android-helper ] && git clone --depth 1 --branch main https://github.com/media-kit/media-kit-android-helper.git

cd ..
