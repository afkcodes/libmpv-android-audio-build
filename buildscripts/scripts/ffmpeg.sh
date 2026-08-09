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
	--disable-postproc \
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
	--enable-hwaccels \
	--enable-optimizations \
	--enable-runtime-cpudetect \
	\
	--enable-mbedtls \
	\
	--enable-libxml2 \
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
	--enable-decoder=ljpeg \
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
	--enable-filter=overlay \
	\
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
	--enable-protocol=hls \
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
	--enable-protocol=srt \
	\
	--enable-encoder=mjpeg \
	--enable-encoder=ljpeg \
	--enable-encoder=jpegls \
	--enable-encoder=jpeg2000 \
	--enable-encoder=png \
	--enable-encoder=jpegls \
	\
	--enable-network \

make -j$cores
make DESTDIR="$prefix_dir" install
