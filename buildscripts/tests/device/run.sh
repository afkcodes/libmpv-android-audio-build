#!/bin/bash -e
#
# On-device verification of a built libmpv, over adb.
#
#     buildscripts/tests/device/run.sh [abi]          # default arm64-v8a
#     LIBMPV=/path/to/other/libmpv.so run.sh          # A/B against another .so
#
# WHY THIS EXISTS, next to tests/run.sh and tests/probe-artifact.sh:
#
#   probe-artifact.sh reads the FILE. It proves a symbol is exported and a
#   string is present — registration, not behaviour. "filter present" is not
#   "filter configures".
#   tests/run.sh runs on the HOST and covers exactly one feature, the prefetch
#   hook. It never touches decode, filters, HLS, iconv or the PCM tap.
#
# This runs the SHIPPED, STRIPPED .so on a real phone and makes it actually
# demux, decode, filter, stream and tap. It was written for the size-reduction
# work (rn-media #30), where the whole question is whether a removal broke
# something no file-level check can see.
#
# ao=null, so it needs no JavaVM and no app: the PCM tap sits at the end of
# ao_post_process_data(), which audio/out/buffer.c drives for EVERY audio
# output, so the tap still fires. AudioTrack itself is NOT covered here — that
# needs the example app; see the #30 report.
#
# Media is generated with the host's ffmpeg and served to the device over
# `adb reverse`, so the whole run is hermetic: no public test stream, nothing
# that can rot or rate-limit.
#
# Requires: adb with a device attached, host ffmpeg, host python3, and the NDK
# that include/depinfo.sh pins.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
. ./include/depinfo.sh

ABI="${1:-arm64-v8a}"
PORT="${PORT:-8099}"
DEV=/data/local/tmp/rnmedia
NDK=sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
LIBMPV="${LIBMPV:-$PWD/prefix/$ABI/lib/libmpv.so}"

case "$ABI" in
    arm64-v8a)   CC=aarch64-linux-android21-clang ;;
    armeabi-v7a) CC=armv7a-linux-androideabi21-clang ;;
    x86)         CC=i686-linux-android21-clang ;;
    x86_64)      CC=x86_64-linux-android21-clang ;;
    *) echo "unknown abi $ABI" >&2; exit 1 ;;
esac

command -v adb >/dev/null || { echo "adb not found" >&2; exit 1; }
[ -n "$(adb devices | sed -n '2p')" ] || { echo "no device attached" >&2; exit 1; }
[ -f "$LIBMPV" ] || { echo "missing $LIBMPV — build it first" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup () {
    [ -n "${HTTPD:-}" ] && kill "$HTTPD" 2>/dev/null
    adb reverse --remove tcp:$PORT 2>/dev/null
    adb shell rm -rf $DEV 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> generating media (host ffmpeg)"
mkdir -p "$WORK/m/hls"
cd "$WORK/m"
ffmpeg -hide_banner -loglevel error -f lavfi \
    -i "sine=frequency=440:sample_rate=44100:duration=3" -ac 2 tone.wav
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a flac        tone.flac
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a aac -b:a 128k tone.m4a
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a libvorbis   tone.ogg
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a libopus     tone.opus
ffmpeg -hide_banner -loglevel error -y -i tone.wav                  tone.mp3
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a flac -f matroska tone.mka
ffmpeg -hide_banner -loglevel error -y -i tone.wav -c:a aac -b:a 128k \
    -f hls -hls_time 1 -hls_playlist_type vod \
    -hls_segment_filename "hls/seg%d.ts" hls/index.m3u8
ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i "sine=frequency=440:sample_rate=44100:duration=180" -ac 2 -c:a flac long.flac

# A CUE SHEET IN CP1251 — the only one of these that exercises libiconv.
# demux_cue.c hands raw file bytes to mp_charset_guess()/mp_iconv_to_utf8().
# An ID3 tag CANNOT test iconv: FFmpeg's ID3 parser has already re-encoded the
# payload into valid UTF-8 by the time mpv sees it, and mp_charset_guess() then
# says "Data looks like UTF-8, ignoring user-provided charset" — correctly.
python3 -c "
open('tone.cue','wb').write('''PERFORMER \"Исполнитель\"
TITLE \"Альбом\"
FILE \"tone.flac\" WAVE
  TRACK 01 AUDIO
    TITLE \"Пример\"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE \"Второй\"
    INDEX 01 00:01:50
'''.encode('cp1251'))"
cd - >/dev/null

echo "==> cross-compiling for $ABI"
export PATH="$PWD/$NDK:$PATH"
$CC -O1 -Wall -Wextra -Wno-unused-parameter -I deps/mpv/include \
    -o "$WORK/engine_test" tests/device/engine_test.c \
    -L "$(dirname "$LIBMPV")" -lmpv
$CC -O2 -Wall -I deps/mpv/include \
    -o "$WORK/perf_test" tests/device/perf_test.c \
    -L "$(dirname "$LIBMPV")" -lmpv

echo "==> pushing (stripped .so, i.e. what a release jar contains)"
cp "$LIBMPV" "$WORK/libmpv.so"
"$NDK/llvm-strip" --strip-all "$WORK/libmpv.so"
adb shell "rm -rf $DEV; mkdir -p $DEV"
adb push "$WORK/libmpv.so" "$DEV/libmpv.so" >/dev/null
adb push "$WORK/engine_test" "$DEV/engine_test" >/dev/null
adb push "$WORK/perf_test" "$DEV/perf_test" >/dev/null
for f in "$WORK"/m/*.wav "$WORK"/m/*.flac "$WORK"/m/*.mp3 "$WORK"/m/*.m4a \
         "$WORK"/m/*.ogg "$WORK"/m/*.opus "$WORK"/m/*.mka "$WORK"/m/*.cue; do
    adb push "$f" "$DEV/$(basename "$f")" >/dev/null
done
adb shell "chmod 755 $DEV/engine_test $DEV/perf_test"

echo "==> serving media over adb reverse (port $PORT)"
(cd "$WORK/m" && python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
HTTPD=$!
sleep 1
adb reverse tcp:$PORT tcp:$PORT >/dev/null

echo "==> running"
adb shell "cd $DEV && LD_LIBRARY_PATH=$DEV ./engine_test http://127.0.0.1:$PORT"
rc=$?

echo
echo "==> CPU (decode + 9-filter EQ over 180 s of FLAC, as fast as it goes)"
adb shell "cd $DEV && LD_LIBRARY_PATH=$DEV ./perf_test"

exit $rc
