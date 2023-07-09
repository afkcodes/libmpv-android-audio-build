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

../configure \
	--target-os=android --enable-cross-compile --cross-prefix=$ndk_triple- --cc=$CC \
	--arch=${ndk_triple%%-*} --cpu=$cpu --pkg-config=pkg-config \
	--extra-cflags="-I$prefix_dir/include $cpuflags" --extra-ldflags="-L$prefix_dir/lib" \
	\
	--disable-gpl \
	--disable-nonfree \
	--disable-static \
	--disable-vulkan \
	\
	--disable-muxers \
	--disable-decoders \
	--disable-encoders \
	--disable-demuxers \
	--disable-parsers \
	--disable-protocols \
	--disable-devices \
	--disable-filters \
	\
	--disable-stripping \
	\
	--disable-doc \
	--disable-programs \
	--disable-gray \
	--disable-swscale-alpha \
	--disable-avdevice \
	--disable-postproc \
	--disable-dxva2 \
	--disable-vaapi \
	--disable-vdpau \
	--disable-videotoolbox \
	--disable-audiotoolbox \
	--disable-iconv \
	--disable-linux-perf \
	--disable-bzlib \
	--disable-bsf=mjpeg2jpeg \
	--disable-bsf=mjpega_dump_header \
	--disable-bsf=mov2textsub \
	--disable-bsf=text2movsub \
	--disable-bsf=eac3_core \
	\
	--enable-jni \
	--enable-version3 \
	\
	--enable-mediacodec \
	\
	--enable-mbedtls \
	--enable-libdav1d \
	\
	--enable-bsfs \
	--enable-small \
	--enable-shared \
	--enable-optimizations \
	--enable-runtime-cpudetect \
	\
	--enable-avutil \
	--enable-avcodec \
	--enable-avfilter \
	--enable-avformat \
	\
	--enable-swscale \
	--enable-swresample \
	\
	--enable-network \
	\
	--enable-decoder=flv \
	--enable-decoder=flv \
	--enable-decoder=h263 \
	--enable-decoder=h263i \
	--enable-decoder=h263p \
	--enable-decoder=h264 \
	--enable-decoder=mpeg1video \
	--enable-decoder=mpeg2video \
	--enable-decoder=mpeg4 \
	--enable-decoder=vp6 \
	--enable-decoder=vp6a \
	--enable-decoder=vp6f \
	--enable-decoder=vp8 \
	--enable-decoder=vp9 \
	--enable-decoder=hevc \
	--enable-decoder=libdav1d \
    \
	--enable-decoder=aac \
	--enable-decoder=aac_latm \
	--enable-decoder=mp3* \
	--enable-decoder=flac \
	--enable-decoder=alac \
	--enable-decoder=pcm_* \
	--enable-decoder=opus \
	--enable-decoder=vorbis \
	\
	--enable-encoder=png \
	--enable-encoder=mjpeg \
	\
	--enable-muxer=mpegts \
	--enable-muxer=mp4 \
	\
	--enable-demuxer=aac \
	--enable-demuxer=concat \
	--enable-demuxer=data \
	--enable-demuxer=flv \
	--enable-demuxer=hls \
	--enable-demuxer=latm \
	--enable-demuxer=live_flv \
	--enable-demuxer=loas \
	--enable-demuxer=m4v \
	--enable-demuxer=mov \
	--enable-demuxer=mp3 \
	--enable-demuxer=mpegps \
	--enable-demuxer=mpegts \
	--enable-demuxer=mpegvideo \
	--enable-demuxer=hevc \
	--enable-demuxer=rtsp \
	--enable-demuxer=mpeg4 \
	--enable-demuxer=mjpeg \
	--enable-demuxer=avi \
	--enable-demuxer=av1 \
	--enable-demuxer=matroska \
	--enable-demuxer=dash \
	--enable-demuxer=webm_dash_manifest \
	\
	--enable-parser=aac \
	--enable-parser=aac_latm \
	--enable-parser=h263 \
	--enable-parser=h264 \
	--enable-parser=flac \
	--enable-parser=hevc \
	--enable-parser=mpeg4 \
	--enable-parser=mpeg4video \
	--enable-parser=mpegvideo \
	\
	--enable-filter=equalizer \
	\
	--enable-protocol=async \
	--enable-protocol=ffrtmphttp \
	--enable-protocol=rtmp \
	--enable-protocol=rtmpt \
	--enable-protocol=rtsp \
	--enable-protocol=rtmp* \
	--enable-protocol=rtp \
	--enable-protocol=udp \
	--enable-protocol=tcp \
	--enable-protocol=pipe \

make -j$cores
make DESTDIR="$prefix_dir" install

ln -sf "$prefix_dir"/lib/libswresample.so "$native_dir"
ln -sf "$prefix_dir"/lib/libpostproc.so "$native_dir"
ln -sf "$prefix_dir"/lib/libavutil.so "$native_dir"
ln -sf "$prefix_dir"/lib/libavcodec.so "$native_dir"
ln -sf "$prefix_dir"/lib/libavformat.so "$native_dir"
ln -sf "$prefix_dir"/lib/libswscale.so "$native_dir"
ln -sf "$prefix_dir"/lib/libavfilter.so "$native_dir"
ln -sf "$prefix_dir"/lib/libavdevice.so "$native_dir"
