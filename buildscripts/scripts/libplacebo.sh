#!/bin/bash -e

# libplacebo — a dependency this fork does not want and cannot avoid.
#
# mpv 0.37.0 removed the `libplacebo` build option and made it an
# unconditional `dependency()`. It is not confined to the video path: core
# translation units this audio-only build compiles anyway (demux/demux_mkv.c,
# filters/f_lavfi.c, player/main.c, video/mp_image.c, video/sws_utils.c)
# include its headers, so mpv cannot be configured without it. libass CAN be
# stripped (patches/mpv/003), libplacebo cannot — the surface is spread through
# colour-space handling that mpv's own core uses.
#
# Everything that makes libplacebo big is a GPU backend, and every one of them
# is disabled here: no Vulkan, no OpenGL, no D3D11, no shader compilers, no
# demos, no tests. What is left is the colour/format core, built static, so the
# linker pulls in only the objects mpv actually reaches.
#
# LGPLv2.1+ (libplacebo's own LICENSE), so it does not disturb this build's
# LGPLv3 line: still no --enable-gpl anywhere.

. ../../include/depinfo.sh
. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

# meson refuses to combine a cross file with ambient compiler env vars.
unset CC CXX

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dvulkan=disabled \
	-Dopengl=disabled \
	-Dd3d11=disabled \
	-Dshaderc=disabled \
	-Dglslang=disabled \
	-Dlcms=disabled \
	-Dlibdovi=disabled \
	-Dxxhash=disabled \
	-Ddemos=false \
	-Dtests=false

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

# libplacebo is C++ internally but ships a C API, so its .pc file does not
# name the C++ runtime. Static-linking it into libmpv.so therefore leaves
# __cxa_* / operator new unresolved unless -lc++ is added by hand. Upstream
# mpv-android carries the same one-liner; it is "-lc++" and not "-lstdc++"
# because meson mis-maps the latter on the NDK
# (https://github.com/mesonbuild/meson/issues/11300).
${SED:-sed} -i '/^Libs:/ s|$| -lc++|' "$prefix_dir/lib/pkgconfig/libplacebo.pc"
