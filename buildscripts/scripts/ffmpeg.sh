#!/bin/bash -e

. ../../include/depinfo.sh
. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf _build$ndk_suffix
	exit 0
else
	exit 255
fi

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

cpu=armv7-a
[[ "$ndk_triple" == "aarch64"* ]] && cpu=armv8-a
[[ "$ndk_triple" == "x86_64"* ]] && cpu=generic
[[ "$ndk_triple" == "i686"* ]] && cpu="i686 --disable-asm"

cpuflags=
[[ "$ndk_triple" == "arm"* ]] && cpuflags="$cpuflags -mfpu=neon -mcpu=cortex-a8"

# ---------------------------------------------------------------------------
# HLS support (rn-media)
#
# `--disable-demuxers` below makes the explicit allow-list the whole world, and
# it contained neither `hls` nor `mpegts`, so every `.m3u8` failed to demux even
# though `--enable-protocol=hls` was already present (that is the deprecated
# `hls://` *protocol*, not the demuxer, and it is useless on its own).
#
#   --enable-demuxer=hls      libavformat/hls.c, the actual HLS implementation.
#   --enable-demuxer=mpegts   the container of `.ts` media segments. FFmpeg's
#                             configure:3439 declares
#                               hls_demuxer_select="adts_header ac3_parser
#                                                   mov_demuxer mpegts_demuxer"
#                             so it would be pulled in implicitly anyway; it is
#                             listed explicitly so the dependency is visible in
#                             the recorded configure line, and so that plain
#                             `.ts` URLs work too.
#
# Everything else HLS needs is already satisfied by the existing allow-list —
# verified against the FFmpeg n6.0 tree this script builds, not from memory:
#   mov demuxer (fMP4 / CMAF segments)        already enabled below
#   ac3 + aac* + mpegaudio parsers            already enabled below
#                                             (hls_demuxer_select needs
#                                              ac3_parser; AAC-in-TS needs the
#                                              aac parser)
#   crypto protocol (#EXT-X-KEY AES-128)      already enabled below; hls.c:1318
#                                             builds `crypto:`/`crypto+` URLs.
#                                             It has no configure `_deps` line,
#                                             so the flag alone compiles
#                                             libavformat/crypto.o (Makefile:650)
#   id3v2 (timed metadata inside segments)    no flag exists or is needed:
#                                             libavformat/Makefile lists id3v2.o
#                                             in the unconditional OBJS block
#
# No GPL/nonfree flag and no new external library is introduced: the bundle
# stays LGPLv3, exactly as before.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Audio filters / EQ + DSP (rn-media)
#
# Same trap as the demuxers: `--disable-filters` below makes the allow-list the
# whole world, and it held exactly two entries -- `overlay` (video) and
# `equalizer`.  `--enable-avfilter` *is* set and mpv's libavfilter bridge
# (filters/f_lavfi.c) *is* compiled, so `af=<name>=...` resolves through
# avfilter_get_by_name(); it simply had nothing to resolve to.  Verified on the
# shipped v1.1.9-rnmedia.1 arm64 binary:
#   _build-arm64/config_components.h -> only CONFIG_EQUALIZER_FILTER 1
#                                       and  CONFIG_OVERLAY_FILTER 1
#
# `aresample` is the load-bearing one and is NOT optional:
# libavfilter/avfiltergraph.c:486-492 auto-inserts `neg->conversion_filter`
# (= "aresample" for audio, ff_default_query_formats/audio negotiation) whenever
# two linked pads cannot agree a format, and if that filter is absent the graph
# config fails outright with "'aresample' filter not present, cannot convert
# formats".  Every filter below pins a *different* sample format --
# superequalizer/firequalizer FLTP, anequalizer/dynaudnorm DBLP, loudnorm /
# crossfeed / acompressor / alimiter DBL (packed), biquads S16P|S32P|FLTP|DBLP --
# and loudnorm additionally pins 192 kHz input in its non-linear mode
# (af_loudnorm.c:734,746).  Without aresample, even a single-filter chain is one
# decoder sample-format away from failing.  Its only configure dep is
# `aresample_filter_deps="swresample"` (configure:3630) and swresample is already
# enabled above -- checked, not assumed.
#
# Everything else here has NO `_deps`/`_select` line in FFmpeg n6.0's configure
# (grepped `^<name>_filter_(deps|select|suggest)=` -- no match for any of them),
# so each flag costs exactly its own object file:
#   volume            af_volume.o          pre-amp / headroom before EQ boost
#   equalizer         af_biquads.o         (already enabled; kept)
#   bass treble       af_biquads.o         shelving; SAME object as equalizer,
#   lowpass highpass  af_biquads.o         so these four are registration-only
#                                          (Makefile:120,137,166 + 1623/1640)
#   anequalizer       af_anequalizer.o     N-band parametric IIR, per-channel
#   superequalizer    af_superequalizer.o  18-band graphic EQ
#   firequalizer      af_firequalizer.o    linear-phase FIR EQ
#   acompressor       af_sidechaincompress.o
#   alimiter          af_alimiter.o        true-peak clip guard after EQ boost
#   dynaudnorm        af_dynaudnorm.o      cheap live loudness levelling
#   loudnorm          af_loudnorm.o + ebur128.o   EBU R128 (expensive: 192 kHz)
#   crossfeed         af_crossfeed.o       headphone crossfeed
#   aformat anull     af_aformat.o/af_anull.o  format pinning + no-op passthrough
#
# superequalizer and firequalizer used to need libavcodec's RDFT; in n6.0 both
# include "libavutil/tx.h" only (af_superequalizer.c:23, af_firequalizer.c:26),
# so they add no avcodec surface.
#
# LICENSING -- checked, this is the whole reason the list is not longer:
# FFmpeg gates GPL-only components with `<name>_filter_deps="gpl"`.  In n6.0
# every single one of those 34 entries (configure:3636-3756) is a *video*
# filter (eq, hqdn3d, delogo, spp, pp, ...).  None of the audio filters above
# carries a gpl dep, and none is named in LICENSE.md's GPL/nonfree sections.
# So: still --disable-gpl --disable-nonfree --enable-version3, i.e. LGPLv3,
# no new external library, no ABI change.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# FFmpeg 6.0 -> 8.1.2 (rn-media)
#
# ONE flag had to go: `--disable-postproc`. libpostproc was removed from the
# FFmpeg tree in 8.0, so configure now rejects the option outright ("Unknown
# option --disable-postproc") and the whole build dies before it starts. It was
# GPL-only and this build never shipped it, so dropping the flag changes
# nothing about the artifact — it only stops asking for something that no
# longer exists.
#
# EVERY other flag below was re-verified against the 8.1.2 configure, and every
# component in the allow-lists was re-verified against 8.1.2's own registration
# tables (libavformat/allformats.c, libavcodec/allcodecs.c, libavcodec/parsers.c,
# libavformat/protocols.c, libavfilter/allfilters.c) rather than against
# memory or a changelog. All 16 audio filters, both HLS demuxers, every decoder,
# parser and protocol still exist under the same name.
#
# THREE entries do not match anything. configure warns and ignores them; the
# build is unaffected. Observed verbatim in the 8.1.2 arm64 configure output:
#   WARNING: Option --enable-decoder=ljpeg did not match anything
#   WARNING: Option --enable-protocol=hls did not match anything
#   WARNING: Option --enable-protocol=srt did not match anything
#
#   --enable-decoder=ljpeg    pre-existing no-op, also silent in 6.0: ljpeg is
#                             an ENCODER only, there has never been an ljpeg
#                             decoder (mjpeg decodes it).
#   --enable-protocol=srt     pre-existing no-op: needs external libsrt, which
#                             is not linked.
#   --enable-protocol=hls     NEW no-op. FFmpeg finally deleted the deprecated
#                             `hls://` protocol. This is the cleanest possible
#                             confirmation of the trap already recorded in
#                             rn-media's ARCHITECTURE ("--enable-protocol=hls
#                             proves nothing"): the flag is gone, and HLS still
#                             works, because what carries it is the DEMUXER —
#                             `CC libavformat/hls.o` in the same build log, and
#                             CONFIG_HLS_DEMUXER=1 in config_components.h.
#
# All three are left in place so this diff stays about the version bump.
# Deleting them is a separate, cosmetic change.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# rn-media parity release (#32)
#
# LIBXML2 REMOVED. FFmpeg uses libxml2 for exactly one thing: the DASH demuxer
# (libavformat/dashdec.c). This build does not enable that demuxer, so the
# shipped artifact was linking an XML parser NOTHING could reach -- dead weight
# and dead attack surface. The darwin fork only ever built libxml2 for its video
# variant, so removing it here is what makes the two AUDIO artifacts match.
# Neither platform has DASH; if we ever want it, both get it together, along
# with libxml2 on both.
#
# IMAGE ENCODERS REMOVED (mjpeg, ljpeg, jpegls, jpeg2000, png). This is an audio
# engine and nothing in rn-media encodes an image; they were inherited from the
# upstream flavour script and darwin never had them. The DECODERS stay, and
# darwin gains them in this same release -- decoding cover art is the feature,
# encoding it was never anything.
#
# ITEM 8 -- zlib. `--enable-zlib` is NEW here and was darwin-only before. zlib in
# libavformat is what decompresses Matroska COMPRESSED TRACK HEADERS, so a .mka
# using header compression was a candidate for playing on iOS and failing on
# Android. It costs nothing: the NDK sysroot ships zlib.h and libz.so at API 21,
# so this adds one DT_NEEDED (libz.so) and no vendored source.
#
# DEAD FLAGS REMOVED -- three entries that matched NOTHING in FFmpeg 8.1.2, each
# of which configure warned about on every single build:
#
#   --enable-decoder=ljpeg   ljpeg is an ENCODER only; there has never been an
#                            ljpeg decoder (mjpeg decodes it). The ENCODER flag
#                            below is real and stays.
#   --enable-protocol=hls    FFmpeg 8.x deleted the deprecated `hls://`
#                            protocol. HLS is carried by the DEMUXER, which is
#                            why it kept working.
#   --enable-protocol=srt    needs external libsrt, which is not linked.
#
# They were previously kept "so the diff stays about the version bump". The
# version bump is long done, and the darwin fork was about to have them copied
# into it wholesale for cover-art parity -- so they are being deleted on both
# forks in this release instead of propagated. What is enabled here should be
# what actually exists.
# ---------------------------------------------------------------------------

../configure \
	--target-os=android --enable-cross-compile --cross-prefix=$ndk_triple- --ar=$AR --cc=$CC --ranlib=$RANLIB \
	--arch=${ndk_triple%%-*} --cpu=$cpu --pkg-config=pkg-config --nm=llvm-nm \
	--extra-cflags="-I$prefix_dir/include $cpuflags" --extra-ldflags="-L$prefix_dir/lib" \
	\
	--disable-gpl \
	--disable-nonfree \
	--enable-version3 \
	--enable-static \
	--disable-shared \
	--disable-vulkan \
	--disable-iconv \
	\
	--disable-muxers \
	--disable-decoders \
	--disable-encoders \
	--disable-demuxers \
	--disable-parsers \
	--disable-protocols \
	--disable-devices \
	--disable-filters \
	--disable-doc \
	--disable-avdevice \
	--disable-programs \
	--disable-gray \
	--disable-swscale-alpha \
	\
	--enable-jni \
	--disable-bsfs \
	--disable-mediacodec \
	\
	--disable-dxva2 \
	--disable-vaapi \
	--disable-vdpau \
	--disable-bzlib \
	--disable-linux-perf \
	--disable-videotoolbox \
	--disable-audiotoolbox \
	\
	--enable-small \
	`# --disable-hwaccels, was --enable-hwaccels (rn-media #30). Worth ZERO` \
	`# bytes either way and that is the point: every hwaccel in FFmpeg 8.1.2` \
	`# needs one of dxva2 / vaapi / vdpau / videotoolbox / mediacodec /` \
	`# vulkan / d3d11va / nvdec, and this script disables all of them, so` \
	`# the built tree has CONFIG_*_HWACCEL 1 exactly 0 times (counted in` \
	`# _build-arm64/config_components.h). It was the same class of dead flag` \
	`# as the three the parity release deleted -- asking for something this` \
	`# build cannot have -- and it read like a capability in the recorded` \
	`# configure line. Stated in the negative so it stays a decision.` \
	--disable-hwaccels \
	--enable-optimizations \
	--enable-runtime-cpudetect \
	\
	--enable-mbedtls \
	\
	--enable-zlib \
	\
	--enable-avutil \
	--enable-avcodec \
	--enable-avfilter \
	--enable-avformat \
	--enable-swscale \
	--enable-swresample \
	\
	--enable-decoder=aac* \
	--enable-decoder=ac3 \
	--enable-decoder=alac \
	--enable-decoder=als \
	--enable-decoder=ape \
	--enable-decoder=atrac* \
	--enable-decoder=eac3 \
	--enable-decoder=flac \
	--enable-decoder=gsm* \
	--enable-decoder=mp1* \
	--enable-decoder=mp2* \
	--enable-decoder=mp3* \
	--enable-decoder=mpc* \
	--enable-decoder=opus \
	--enable-decoder=ra* \
	--enable-decoder=ralf \
	--enable-decoder=shorten \
	--enable-decoder=tak \
	--enable-decoder=tta \
	--enable-decoder=vorbis \
	--enable-decoder=wavpack \
	--enable-decoder=wma* \
	--enable-decoder=pcm* \
	--enable-decoder=dsd* \
 	--enable-decoder=dca \
	--enable-decoder=truehd \
	\
	--enable-decoder=mjpeg \
	--enable-decoder=jpegls \
	--enable-decoder=jpeg2000 \
	--enable-decoder=png \
	--enable-decoder=gif \
	--enable-decoder=bmp \
	--enable-decoder=tiff \
	--enable-decoder=webp \
	--enable-decoder=jpegls \
	\
	--enable-demuxer=aac \
	--enable-demuxer=ac3 \
	--enable-demuxer=aiff \
	--enable-demuxer=ape \
	--enable-demuxer=asf \
	--enable-demuxer=au \
	--enable-demuxer=avi \
	--enable-demuxer=flac \
	--enable-demuxer=flv \
	--enable-demuxer=matroska \
	--enable-demuxer=mov \
	--enable-demuxer=m4v \
	--enable-demuxer=mp3 \
	--enable-demuxer=mpc* \
	--enable-demuxer=ogg \
	--enable-demuxer=pcm* \
	--enable-demuxer=rm \
	--enable-demuxer=shorten \
	--enable-demuxer=tak \
	--enable-demuxer=tta \
	--enable-demuxer=wav \
	--enable-demuxer=wv \
	--enable-demuxer=xwma \
	--enable-demuxer=dsf \
	--enable-demuxer=dts \
	--enable-demuxer=truehd \
	--enable-demuxer=dts \
	--enable-demuxer=dtshd \
	--enable-demuxer=hls \
	--enable-demuxer=mpegts \
	\
	--enable-parser=aac* \
	--enable-parser=ac3 \
	--enable-parser=cook \
	--enable-parser=dca \
	--enable-parser=flac \
	--enable-parser=gsm \
	--enable-parser=mpegaudio \
	--enable-parser=tak \
	--enable-parser=vorbis \
  	--enable-parser=dca \
	\
	`# NOTE: --enable-filter=overlay is GONE (rn-media #30, size).` \
	`# overlay is a VIDEO filter: it composites one video frame onto` \
	`# another. It predates every audio flag in this list -- it is one of` \
	`# the two entries the upstream flavour script shipped ("the allow-list` \
	`# below held exactly two entries -- overlay (video) and equalizer"),` \
	`# so it was inherited, never chosen. In an engine that runs vid=no /` \
	`# vo=null there is no video frame for it to composite onto and no` \
	`# filter graph that can instantiate it: mpv reaches libavfilter only` \
	`# through filters/f_lavfi.c, and the audio graph rejects a video` \
	`# filter at format negotiation. Cost measured on arm64: vf_overlay.o` \
	`# 50,080 B plus the two objects only it pulls, framesync.o 3,956 and` \
	`# drawutils.o 6,956 (linker --why-extract, not guesswork).` \
	`# The 17 AUDIO filters below are untouched.` \
	--enable-filter=aresample \
	--enable-filter=aformat \
	--enable-filter=anull \
	--enable-filter=volume \
	--enable-filter=equalizer \
	--enable-filter=bass \
	--enable-filter=treble \
	--enable-filter=lowpass \
	--enable-filter=highpass \
	--enable-filter=anequalizer \
	--enable-filter=superequalizer \
	--enable-filter=firequalizer \
	--enable-filter=acompressor \
	--enable-filter=alimiter \
	--enable-filter=dynaudnorm \
	--enable-filter=loudnorm \
	--enable-filter=crossfeed \
	\
	--enable-protocol=async \
	--enable-protocol=cache \
	--enable-protocol=crypto \
	--enable-protocol=data \
	--enable-protocol=ffrtmphttp \
	--enable-protocol=file \
	--enable-protocol=ftp \
	--enable-protocol=http \
	--enable-protocol=httpproxy \
	--enable-protocol=https \
	--enable-protocol=pipe \
	--enable-protocol=rtmp \
	--enable-protocol=rtmps \
	--enable-protocol=rtmpt \
	--enable-protocol=rtmpts \
	--enable-protocol=rtp \
	--enable-protocol=subfile \
	--enable-protocol=tcp \
	--enable-protocol=tls \
	\
	\
	--enable-network \

make -j$cores
make DESTDIR="$prefix_dir" install
