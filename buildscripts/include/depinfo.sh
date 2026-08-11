#!/bin/bash -e

## Dependency versions

v_sdk=11076708_latest
v_ndk=27.1.12297006
v_sdk_build_tools=35.0.0

v_mbedtls=3.6.1
v_libxml2=2.10.3
# FFmpeg 8.1.2 ("Hoare" line, 2026-06-17). The floor is mpv 0.41's own
# `dependency('libavcodec', version: '>= 60.31.102')` (meson.build:21), i.e.
# FFmpeg >= 6.1. Deliberately NOT n9.0: that branch was cut 2026-06-26, six
# months AFTER mpv 0.41.0 shipped, has no point release yet, and drops the
# `hls://` protocol this fork's configure line still names. The 8.1 line is
# maintained, and it is the pairing the closest peer — ales-drnz/libmpv-scripts,
# an audio-only libmpv 0.41 build with a PCM tap — documents as verified.
v_ffmpeg=8.1.2
v_mpv=0.41.0
# libplacebo became a MANDATORY dependency of mpv in 0.37.0. The
# `--disable-libplacebo` switch this fork used to pass no longer exists:
# mpv 0.36's meson.build had `option('libplacebo', ...)`, 0.37's has a bare
# `libplacebo = dependency('libplacebo', version: '>=6.338.0')`. It is reached
# from core, non-video translation units (demux/demux_mkv.c, filters/f_lavfi.c,
# player/main.c, video/mp_image.c, video/sws_utils.c), so it cannot be stripped
# the way libass can — it is built with every GPU backend disabled and the
# linker keeps only what those files touch.
#
# 6.338.2, not the newer 7.360.1: 6.338.2 is mpv 0.41's declared minimum, and
# libplacebo 7.x drops symbols mpv 0.41's csputils.h still references under
# mobile cross-files (libmpv-scripts pins 6.338.2 for Android/iOS and 7.x only
# for desktop, with that reason written down). Revisit when mpv ships a release
# built against the 7.x API.
v_libplacebo=6.338.2

## Dependency tree
# I would've used a dict but putting arrays in a dict is not a thing

dep_mbedtls=()
dep_ffmpeg=(libxml2 mbedtls)
dep_libplacebo=()
dep_mpv=(ffmpeg libplacebo)
