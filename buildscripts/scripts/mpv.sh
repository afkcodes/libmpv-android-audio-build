#!/bin/bash -e

# mpv is meson-only from 0.37.0 on ("waf: remove waf as a build system",
# 0.37.0 changelog; 0.36.0's RELEASE_NOTES had already announced "This is the
# last release to contain the waf build system"). Every flag below is the
# meson spelling of the waf flag this script used to pass; the mapping is
# written out because two of them are NOT one-to-one.
#
#   --enable-lgpl           -> -Dgpl=false
#       There is no `lgpl` option. GPL is a permission flag: GPL-only
#       components gate themselves with .require(get_option('gpl')), and since
#       they are all value:'auto' they silently disable. Same licence outcome,
#       opposite polarity.
#   --enable-libmpv-shared  -> -Dlibmpv=true  AND  --default-library shared
#       This one is a trap. libmpv is built with a generic library(), which
#       follows `default_library` — and this fork's crossfile sets
#       default_library = 'static' (correct for every other dep). -Dlibmpv=true
#       alone only controls install:/build_by_default: and would happily
#       produce libmpv.a. Both are required.
#   --disable-libplacebo    -> (gone; see scripts/libplacebo.sh)
#   --disable-cplayer       -> -Dcplayer=false
#   --disable-lua           -> -Dlua=disabled       (a combo, not a feature)
#   --disable-iconv         -> -Diconv=disabled
#   --disable-vulkan        -> -Dvulkan=disabled
#   --disable-manpage-build -> -Dmanpage-build=disabled
#
# PKG_CONFIG="pkg-config --static" has no meson equivalent and dropping it
# silently under-links: meson only asks pkg-config for Libs.private when the
# built-in `prefer_static` option is set, and mpv never passes static:true
# itself. -Dprefer_static=true is that flag. It is safe against the NDK's
# shared-only stubs because cc.find_library() maps it to PREFER_STATIC rather
# than STATIC, so -landroid / -lOpenSLES still resolve.

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

# Export control — the one thing the waf->meson move silently took away.
# mpv's waf build generated a linker version script from libmpv/mpv.def, which
# is why v1.1.9 shipped a .so exporting exactly the 53 names in that file. mpv
# 0.37 deleted mpv.def, and 0.41 relies solely on gnu_symbol_visibility:
# 'hidden' plus the MPV_EXPORT attribute in the public header. That governs
# mpv's OWN objects and does nothing whatsoever to the static archives we link.
# Measured on the first 0.41 build of this fork: 4020 exported symbols instead
# of 55 — every av_*, every adler32, the entire FFmpeg surface.
#
# Not cosmetic: a React Native app routinely loads other media libraries that
# link their own FFmpeg, and a leaked av_* set makes the dynamic linker's choice
# of whose FFmpeg a call binds to essentially arbitrary. See include/mpv.ver.
#
#   --exclude-libs=ALL   keeps static-archive members out of .dynsym
#   --version-script     pins the export list to mpv_* regardless
# Both, not either: exclude-libs is the mechanism, the version script is the
# guarantee, and the guarantee is what rn-media-release.sh can assert on.
# $LDFLAGS must be carried explicitly. meson seeds c_link_args from the
# environment only when the option is not given, so passing -Dc_link_args at all
# REPLACES it — and build.sh's LDFLAGS is where
# `-Wl,-z,max-page-size=16384` lives. Dropping it would silently ship a 4 KB
# aligned .so that fails to load on 16 KB-page Android devices, which is a
# runtime crash on new hardware and invisible in every build log.
ldflags="$LDFLAGS -Wl,--exclude-libs=ALL -Wl,--version-script=$PWD/../../include/mpv.ver"

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--default-library shared \
	-Dprefer_static=true \
	-Dc_link_args="$ldflags" \
	-Dcpp_link_args="$ldflags" \
	-Dgpl=false \
	-Dlibmpv=true \
	-Dcplayer=false \
	-Diconv=disabled \
	-Dlua=disabled \
	-Dvulkan=disabled \
	-Dgl=disabled \
	-Dplain-gl=disabled \
	-Degl-android=disabled \
	-Dandroid-media-ndk=disabled \
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
	-Daudiotrack=enabled \
	-Daaudio=disabled \
	-Dopensles=disabled \
	-Dmanpage-build=disabled \
	-Dhtml-build=disabled \
	-Dpdf-build=disabled

ninja -C $build -j$cores

# meson intermittently ignores --default-library on a reconfigure
# (https://github.com/mesonbuild/meson/issues/11294), and a static libmpv.a
# next to a missing libmpv.so looks like a successful build until the APK has
# no engine in it. Upstream mpv-android carries the same guard.
if [ -f $build/libmpv.a ]; then
	echo >&2 "meson produced a static libmpv despite --default-library shared; rebuilding"
	$0 clean
	exec $0 build
fi

DESTDIR="$prefix_dir" ninja -C $build install

ln -sf "$prefix_dir"/lib/libmpv.so "$native_dir"
