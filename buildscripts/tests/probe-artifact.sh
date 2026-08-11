#!/bin/bash
#
# Zero-feature-loss probe for a built libmpv.so.
#
#     buildscripts/tests/probe-artifact.sh <label> [abi]
#
# It strips a copy of prefix/<abi>/lib/libmpv.so and asserts, ON THE STRIPPED
# ARTIFACT, everything this engine is supposed to be. rn-media-release.sh
# already refuses to package a .so that lacks a patch marker; this is the same
# idea widened to the whole feature surface, and it exists because the size
# work (rn-media #30) needed a gate that a REMOVAL cannot quietly pass:
#
#   1  the five rn-media marker strings (pcm tap x2, prefetch hook x3)
#   2  exactly 55 exports, 0 of them non-mpv_*
#   3  HLS + mpegts + the protocol set, proved by strings only those
#      demuxers/protocols emit
#   4  all 17 FFmpeg AUDIO filters, aresample included
#   5  every LOAD segment aligned to 0x4000 (16 KB-page devices)
#   6  DT_NEEDED is a SUBSET of the baseline allowlist -- a removal is allowed
#      to drop a dependency, nothing is allowed to add one
#   7  the vendored GNU libiconv alias tables, incl. the extra encodings
#   8  zlib, which is linked STATICALLY here (the NDK sysroot ships libz.a and
#      -Dprefer_static=true picks it, so there is no libz.so DT_NEEDED to look
#      for -- assert the code instead)
#   9  engine capabilities: audiotrack AO, prefetch, gapless, ICY/codepage,
#      lavfi bridge, and Android's own mpv_lavc_set_java_vm
#
# Exits non-zero with the count of failures. `overlay` is reported as info,
# not asserted: it is a VIDEO filter and #30 removed it.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LABEL="${1:-unnamed}"
ABI="${2:-arm64-v8a}"
SRC=prefix/$ABI/lib/libmpv.so
. ./include/depinfo.sh
N=sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$SRC" "$OUT/libmpv.unstripped.so"
cp "$SRC" "$OUT/libmpv.so"
$N/llvm-strip --strip-all "$OUT/libmpv.so"
SO="$OUT/libmpv.so"
US="$OUT/libmpv.unstripped.so"
strings -n 2 "$SO" > "$OUT/strings.txt"

FAIL=0
pass () { printf '  ok    %s\n' "$1"; }
fail () { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
has  () { grep -qxF -- "$1" "$OUT/strings.txt"; }        # exact whole-line
hasf () { grep -qF  -- "$1" "$OUT/strings.txt"; }        # substring

echo "=== PROBE [$LABEL] ==="
printf 'size.stripped      %s\n' "$(stat -c%s "$SO")"
printf 'size.unstripped    %s\n' "$(stat -c%s "$US")"
$N/llvm-size -A "$SO" | awk '$1==".text"||$1==".rodata"||$1==".data.rel.ro"||$1==".data"||$1==".bss"{printf "sec %-14s %s\n",$1,$2}'

echo "-- 1. patch markers (rn-media-release.sh REQUIRED_STRINGS) --"
while IFS= read -r needle; do
  hasf "$needle" && pass "marker: $needle" || fail "marker: $needle"
done <<'EOF'
[rn-media] pcm-tap window=
pcm-tap-frame
[rn-media] prefetch hook resolved:
on_prefetch_load
prefetch-playlist-entry-id
EOF

echo "-- 2. exports --"
$N/llvm-readelf --dyn-syms "$SO" | awk '$7!="UND"{print $8}' | grep -v '^$' | grep -v '^Name$' | sort -u > "$OUT/exports.txt"
NEXP=$(wc -l < "$OUT/exports.txt"); NNON=$(grep -cv '^mpv_' "$OUT/exports.txt")
[ "$NEXP" = 55 ] && pass "exports.count = 55" || fail "exports.count = $NEXP (want 55)"
[ "$NNON" = 0 ]  && pass "exports.non_mpv = 0" || fail "exports.non_mpv = $NNON (want 0)"

echo "-- 3. HLS / demuxers / protocols --"
for s in hls mpegts mov,mp4,m4a,3gp,3g2,mj2 matroska,webm flac ogg mp3; do
  has "$s" && pass "demuxer name: $s" || fail "demuxer name: $s"
done
for s in 'EXT-X-KEY' 'EXT-X-MEDIA' '#EXTM3U' 'allowed_segment_extensions' 'hls demuxer'; do
  hasf "$s" && pass "hls.c evidence: $s" || fail "hls.c evidence: $s"
done
for s in https tls crypto http tcp file data async cache; do
  has "$s" && pass "protocol: $s" || fail "protocol: $s"
done

echo "-- 4. filters (17 audio + overlay) --"
NF=0
for f in aresample aformat anull volume equalizer bass treble lowpass highpass \
         anequalizer superequalizer firequalizer acompressor alimiter dynaudnorm \
         loudnorm crossfeed; do
  if has "$f"; then NF=$((NF+1)); else fail "filter: $f"; fi
done
[ "$NF" = 17 ] && pass "filters: 17/17 audio (incl. aresample)" || fail "filters: $NF/17 audio"
has overlay && echo "  info  overlay (video filter) present" || echo "  info  overlay (video filter) absent - dropped in stage B"

echo "-- 5. 16 KB page alignment --"
BAD=$($N/llvm-readelf -l "$SO" | awk '/^  LOAD/{print $NF}' | grep -cv '0x4000')
ALL=$($N/llvm-readelf -l "$SO" | awk '/^  LOAD/{print $NF}' | tr '\n' ' ')
[ "$BAD" = 0 ] && pass "LOAD align all 0x4000 ($ALL)" || fail "LOAD align: $ALL"

echo "-- 6. DT_NEEDED allowlist --"
$N/llvm-readelf -d "$SO" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | sort > "$OUT/needed.txt"
printf 'libandroid.so\nlibc.so\nlibdl.so\nlibm.so\n' > "$OUT/needed.expect"
EXTRA=$(comm -13 "$OUT/needed.expect" "$OUT/needed.txt")
if [ -z "$EXTRA" ] && grep -q libc.so "$OUT/needed.txt" && grep -q libm.so "$OUT/needed.txt"; then
  pass "DT_NEEDED (subset of baseline) = $(tr '\n' ' ' < "$OUT/needed.txt")"
else
  fail "DT_NEEDED gained: $EXTRA — $(tr '\n' ' ' < "$OUT/needed.txt")"
fi

echo "-- 7. iconv alias table (vendored GNU libiconv, --enable-extra-encodings) --"
for a in SHIFT_JIS WINDOWS-1251 ISO-8859-1 EUC-KR BIG5 CP932 KOI8-R GB18030; do
  has "$a" && pass "iconv alias: $a" || fail "iconv alias: $a"
done
# Strip-survivable evidence only. These four checks used to read the SYMBOL
# TABLE of the "unstripped" copy, which works when this script is pointed at
# prefix/ but silently fails when it is pointed at a SHIPPED artifact — the
# exact thing it claims to probe. Caught by running it against the .so inside
# a release jar. Now everything here reads .rodata or .dynsym, both of which
# survive --strip-all, so the script is honest for either input.
for a in ISO-2022-JP-2 EUC-JISX0213 GEORGIAN-ACADEMY CP1258; do
  has "$a" && pass "iconv: extra-encodings table entry $a" || fail "iconv: $a missing (--enable-extra-encodings)"
done

echo "-- 8. zlib (statically linked from NDK sysroot libz.a) --"
# zlib is linked STATICALLY from the NDK sysroot's libz.a and hidden from
# .dynsym by --exclude-libs=ALL, so there is no DT_NEEDED and no dynamic
# symbol to look for. Its inflate error strings are in .rodata and survive.
for z in 'invalid distance too far back' 'incorrect header check'; do
  hasf "$z" && pass "zlib: inflate error string present ($z)" || fail "zlib: '$z' missing"
done

echo "-- 9. engine capabilities --"
for s in 'audiotrack' 'prefetch-playlist' 'gapless-audio' 'metadata-codepage' \
         'af-command' 'lavfi-complex' 'demuxer-lavf' 'stream-open-filename' \
         'replaygain-track-gain' 'audio-out-params' 'cache-secs' 'user-agent'; do
  hasf "$s" && pass "cap: $s" || fail "cap: $s"
done
grep -qx 'mpv_lavc_set_java_vm' "$OUT/exports.txt" && pass "cap: mpv_lavc_set_java_vm exported" || fail "cap: mpv_lavc_set_java_vm not exported"

echo "-- RESULT [$LABEL]: $FAIL failure(s) --"
exit $FAIL
