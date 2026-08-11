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

# EXHAUSTIVE OPTION LIST (rn-media parity release, #32).
#
# This script used to name 27 options and leave the other ~95 at mpv's own
# defaults -- and most mpv features default to `auto`, meaning "build me in if
# my dependency happens to resolve". The only thing keeping them out was the NDK
# sysroot not happening to satisfy a probe, which is not a decision, it is luck.
#
# That is not hypothetical. mpv 0.41 added `avfoundation` with value auto, and
# its dependency resolves on iOS as well as macOS, so the darwin fork silently
# built a SECOND audio output into an audio-only engine until someone noticed.
# The next mpv release can do the same here with any option the NDK satisfies.
#
# So the list below is now the same exhaustive one the darwin fork passes, with
# the platform's own choices on top: audiotrack instead of audiounit, and iconv
# ENABLED because we now vendor libiconv (see scripts/libiconv.sh). Both forks
# now state every option explicitly, which means `workshop dry-run` can diff a
# candidate mpv's meson options against what we pass and flag anything new.

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--default-library shared \
	-Dprefer_static=true \
	-Dc_link_args="$ldflags" \
	-Dcpp_link_args="$ldflags" \
	\
	`# What this build IS` \
	-Dgpl=false \
	-Dlibmpv=true \
	-Dbuild-date=true \
	-Dcplayer=false \
	-Dtests=false \
	-Daudiotrack=enabled \
	-Diconv=enabled \
	\
	-Dfuzzers=false \
	-Ddisable-packet-pool=false \
	-Dcdda=disabled \
	-Dcplugins=disabled \
	-Ddvbin=disabled \
	-Ddvdnav=disabled \
	-Djavascript=disabled \
	-Dlcms2=disabled \
	-Dlibarchive=disabled \
	-Dlibavdevice=disabled \
	-Dlibbluray=disabled \
	-Dlua=disabled \
	-Dpthread-debug=disabled \
	-Drubberband=disabled \
	-Dsdl2-gamepad=disabled \
	-Duchardet=disabled \
	-Duwp=disabled \
	-Dvapoursynth=disabled \
	-Dvector=disabled \
	-Dwin32-smtc=disabled \
	-Dwin32-threads=disabled \
	-Dx11-clipboard=disabled \
	-Dzimg=disabled \
	-Dzlib=disabled \
	-Dalsa=disabled \
	-Daudiounit=disabled \
	-Davfoundation=disabled \
	-Daaudio=disabled \
	-Dcoreaudio=disabled \
	-Djack=disabled \
	-Dopenal=disabled \
	-Dopensles=disabled \
	-Doss-audio=disabled \
	-Dpipewire=disabled \
	-Dpulse=disabled \
	-Dsdl2-audio=disabled \
	-Dsndio=disabled \
	-Dwasapi=disabled \
	-Dcaca=disabled \
	-Dcocoa=disabled \
	-Dd3d11=disabled \
	-Ddirect3d=disabled \
	-Ddmabuf-wayland=disabled \
	-Ddrm=disabled \
	-Degl=disabled \
	-Degl-android=disabled \
	-Degl-angle=disabled \
	-Degl-angle-lib=disabled \
	-Degl-angle-win32=disabled \
	-Degl-drm=disabled \
	-Degl-wayland=disabled \
	-Degl-x11=disabled \
	-Dgbm=disabled \
	-Dgl=disabled \
	-Dgl-cocoa=disabled \
	-Dgl-dxinterop=disabled \
	-Dgl-win32=disabled \
	-Dgl-x11=disabled \
	-Djpeg=disabled \
	-Dsdl2-video=disabled \
	-Dshaderc=disabled \
	-Dsixel=disabled \
	-Dspirv-cross=disabled \
	-Dplain-gl=disabled \
	-Dvdpau=disabled \
	-Dvdpau-gl-x11=disabled \
	-Dvaapi=disabled \
	-Dvaapi-drm=disabled \
	-Dvaapi-wayland=disabled \
	-Dvaapi-win32=disabled \
	-Dvaapi-x11=disabled \
	-Dvulkan=disabled \
	-Dwayland=disabled \
	-Dx11=disabled \
	-Dxv=disabled \
	-Dandroid-media-ndk=disabled \
	-Dcuda-hwaccel=disabled \
	-Dcuda-interop=disabled \
	-Dd3d-hwaccel=disabled \
	-Dd3d9-hwaccel=disabled \
	-Dgl-dxinterop-d3d9=disabled \
	-Dios-gl=disabled \
	-Dvideotoolbox-gl=disabled \
	-Dvideotoolbox-pl=disabled \
	-Dmacos-10-15-4-features=disabled \
	-Dmacos-11-features=disabled \
	-Dmacos-11-3-features=disabled \
	-Dmacos-12-features=disabled \
	-Dmacos-cocoa-cb=disabled \
	-Dmacos-media-player=disabled \
	-Dmacos-touchbar=disabled \
	-Dswift-build=disabled \
	-Dswift-flags= \
	-Dhtml-build=disabled \
	-Dmanpage-build=disabled \
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
