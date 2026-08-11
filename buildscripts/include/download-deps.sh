#!/bin/bash -e

. ./include/depinfo.sh

[ -z "$WGET" ] && WGET=wget

# rn-media parity release (#32): every source is now VERIFIED after fetching.
#
# Before this, every dependency here was a shallow clone of a mutable TAG and
# nothing checked what arrived -- while the darwin fork carried a sha256 on all
# 22 of its sources. A tag can be moved; a shallow clone proves nothing. That
# asymmetry meant the Android half of this engine had a strictly weaker supply
# chain than the iOS half, for no reason anyone had chosen.
#
# Two mechanisms, because the sources come in two shapes:
#
#   verify_commit   for git clones. A commit SHA is content-addressed: it names
#                   the tree, the parents and the message, so re-pointing the
#                   tag cannot change what a SHA resolves to. Cloning by tag and
#                   then asserting the SHA keeps submodules working (libplacebo
#                   needs five of them, and release tarballs ship those
#                   directories EMPTY), which a switch to tarballs would break.
#   sha256sum -c    for real tarballs (libiconv), where the bytes are the thing.
#
# The SHAs below were resolved from each project's own git refs. To bump a
# dependency: change the version in include/depinfo.sh, then update the SHA here
# to whatever the new tag points at -- and if the two ever disagree, the build
# stops instead of building something nobody chose.

# The commit each pinned tag resolved to, verified after every clone.
sha_mbedtls=068ff080b369adfac81509f9b57b2afabaf82dc5
sha_ffmpeg=38b88335f99e76ed89ff3c93f877fdefce736c13
sha_libplacebo=64c1954570f1cd57f8570a57e51fb0249b57bb90
sha_mpv=41f6a645068483470267271e1d09966ca3b9f413
sha_media_kit_android_helper=42054e5d479f39ccbb0ae604862e2bcaf59b74c2

verify_commit () {
	local dir="$1" want="$2" got
	got=$(git -C "$dir" rev-parse HEAD)
	if [ "$got" != "$want" ]; then
		printf >&2 '\e[1;31m%s\e[m\n' "$dir: expected commit $want, got $got"
		printf >&2 '%s\n' "The tag moved, or the clone is not what this build was pinned to. Refusing to continue."
		exit 1
	fi
	echo "$dir: verified $got"
}

mkdir -p deps && cd deps

# mbedtls
[ ! -d mbedtls ] && git clone --depth 1 --branch v$v_mbedtls --recurse-submodules https://github.com/Mbed-TLS/mbedtls.git mbedtls
verify_commit mbedtls "$sha_mbedtls"

# libxml2 is no longer fetched: FFmpeg uses it only for the DASH demuxer, which
# this build does not enable, so it was an XML parser nothing could reach. See
# include/depinfo.sh.

# ffmpeg
[ ! -d ffmpeg ] && git clone --depth 1 --branch n$v_ffmpeg https://github.com/FFmpeg/FFmpeg.git ffmpeg
verify_commit ffmpeg "$sha_ffmpeg"

# libplacebo — mandatory for mpv >= 0.37 (see depinfo.sh).
#
# --recursive is load-bearing: libplacebo keeps its build-time helpers
# (glad, fast_float, jinja, markupsafe, Vulkan-Headers) as submodules, and the
# crossfile sets wrap_mode = 'nodownload', so meson will NOT fetch them at
# configure time. Without them configure fails on the glad generator.
#
# github.com/haasn (libplacebo's own author) rather than the canonical
# code.videolan.org: the latter refuses connections from some networks
# ("Recv failure: Connection reset by peer", hit here on 2026-08-11), and a
# build that cannot fetch a mandatory dependency is not a build. Same tags,
# same history — it is upstream's own mirror.
[ ! -d libplacebo ] && git clone --depth 1 --branch v$v_libplacebo --recursive https://github.com/haasn/libplacebo.git libplacebo
verify_commit libplacebo "$sha_libplacebo"

# libiconv (Android-only; see scripts/libiconv.sh for why we vendor it).
#
# Fetched as a TARBALL WITH A CHECKSUM, unlike everything else here, which is
# cloned by tag and verified not at all. A tag is mutable and a shallow clone
# proves nothing about what arrived; this is the shape the rest of these
# dependencies should move to, and there is no reason to add a new one in the
# weaker form. sha256 from ftp.gnu.org/pub/gnu/libiconv.
v_libiconv_sha256=88dd96a8c0464eca144fc791ae60cd31cd8ee78321e67397e25fc095c4a19aa6
if [ ! -d libiconv ]; then
	$WGET -O libiconv.tar.gz "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$v_libiconv.tar.gz"
	echo "$v_libiconv_sha256  libiconv.tar.gz" | sha256sum -c -
	mkdir libiconv
	tar -xzf libiconv.tar.gz -C libiconv --strip-components=1
	rm -f libiconv.tar.gz
fi

# mpv
[ ! -d mpv ]  && git clone --depth 1 --branch v$v_mpv https://github.com/mpv-player/mpv.git mpv
verify_commit mpv "$sha_mpv"

# media-kit-android-helper
# Pinned to a COMMIT, not to `main`: this used to track a moving branch, so two
# builds a week apart could package different helper code with no version
# change anywhere. Cloned at the branch then asserted, since a shallow clone
# cannot fetch an arbitrary SHA.
[ ! -d media-kit-android-helper ] && git clone --depth 1 --branch main https://github.com/media-kit/media-kit-android-helper.git
verify_commit media-kit-android-helper "$sha_media_kit_android_helper"

cd ..
