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
	--enable-filter=equalizer \
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
