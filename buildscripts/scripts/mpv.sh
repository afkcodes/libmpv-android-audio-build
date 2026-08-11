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
# libiconv is the one dependency here with NO pkg-config file, so meson's
# dependency('iconv') cannot find it the way it finds ffmpeg and libplacebo
# (PKG_CONFIG_LIBDIR, set in include/path.sh). It falls back to a header check
# plus cc.find_library('iconv'), and neither searches our prefix -- build.sh's
# LDFLAGS carries only link-behaviour flags and CFLAGS is unset. So the prefix
# has to be named explicitly here, or -Diconv=enabled fails meson outright with
# "iconv was not found!".
#
# --exclude-libs=ALL below still applies: libiconv is linked statically and its
# symbols stay out of .dynsym, so this adds a capability and not an export.
# rn-media #30 (size). -ffunction-sections/-fdata-sections gives the LINKER
# per-function granularity inside every mpv object; --gc-sections below then
# drops what nothing references. This is not a heuristic — it removes only
# code with no path from a GC root (the 55 exported mpv_* symbols plus the
# init arrays), and the proof that it is finding real dead code rather than
# shaving noise is in the UNDEFINED symbols that disappear with it:
#     regcomp/regexec/regfree   sub/filter_regex.c (a SUBTITLE filter; 003
#                               removed the chain that referenced it, so
#                               sd_filter_regex has had no caller since)
#     ANativeWindow_*           video/out/android_common.c (video surface)
#     ppoll                     osdep/poll_wrapper.c — mp_poll()'s only
#                               callers in 0.41 are clipboard-wayland,
#                               clipboard-x11, dvb_tune, stream_dvb and
#                               drm_common, none of them built here
#     j1                        video/out/filter_kernels.c (scaler windows)
# Each of those is a whole subsystem 007 did not reach. Measured alone on
# arm64: -89,648 B.
mpv_size_cflags="-ffunction-sections -fdata-sections"
iconv_cflags="-I$prefix_dir/include $mpv_size_cflags"
# ...and libiconv is handed to the linker EXPLICITLY, which is the part that
# actually makes mpv's dependency('iconv') resolve.
#
# Two facts about that check, both established by reproducing it locally rather
# than by guessing (the first guess, LIBRARY_PATH, was wrong -- clang's
# -print-search-dirs does not read it):
#
#   * meson tries a BUILTIN check first: it compiles `iconv_open("","")` and
#     links it. GNU libiconv's header macro-renames that to libiconv_open, so
#     the probe needs the archive on the link line or it dies with
#     "undefined symbol: libiconv_open". -L alone does not put it there.
#   * meson's SYSTEM fallback cannot rescue it here either: with
#     -Dprefer_static=true, find_library stops doing a `-liconv` link test and
#     instead SEARCHES the compiler's own library directories, which come from
#     -print-search-dirs and never include our prefix.
#
# So the archive is named directly. -Wl, form on purpose: meson hoists bare -L
# flags to the front of the command but leaves -Wl, args at the end, after the
# object files -- which is the only order in which a static archive resolves
# anything. With this, the builtin check links and iconv is found.
#
# --exclude-libs=ALL below still applies to it, so libiconv's symbols stay out
# of .dynsym: this adds a capability, not an export.
iconv_ldflags="-L$prefix_dir/lib -Wl,-l:libiconv.a"
# --gc-sections is the other half of -ffunction-sections above. Verified not
# to disturb the two things this link already guarantees: the version script
# still yields exactly 55 mpv_* exports (GC roots, so they anchor everything
# reachable), and -Wl,-z,max-page-size=16384 still produces LOAD segments
# aligned to 0x4000 — both asserted on the STRIPPED artifact, not the log.
# It composes with the pre-existing -Wl,-O1,--icf=safe rather than replacing
# it: ICF folds identical survivors, GC deletes non-survivors.
ldflags="$LDFLAGS $iconv_ldflags -Wl,--gc-sections -Wl,--exclude-libs=ALL -Wl,--version-script=$PWD/../../include/mpv.ver"

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

# -Doptimization=s (rn-media #30). The crossfile says buildtype = 'release',
# which is meson's -O3, and -O3 on mpv's OWN code buys nothing measurable
# here: none of the DSP is in this tree. Every hot loop — decode, resample,
# every one of the 17 audio filters — lives in FFmpeg, which is a separate
# build already compiled -Os by --enable-small, and is NOT touched by this
# option. What -O3 was inflating was the player loop, the property system,
# the demuxer glue and the option parser. -Os on those: -183,728 B on arm64,
# measured alone. THIS IS THE ONE FLAG IN THIS FILE WITH A PERFORMANCE
# STORY, and the story is "no DSP is affected" rather than "we measured the
# audio path on a device" — see the experiment report; device verification
# is a precondition for shipping it.
meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Doptimization=s \
	--default-library shared \
	-Dprefer_static=true \
	-Dc_args="$iconv_cflags" \
	-Dcpp_args="$iconv_cflags" \
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
