#!/bin/bash -e

# GNU libiconv, for Android only.
#
# WHY THIS EXISTS
#     mpv uses iconv (misc/charset_conv.c) to turn non-UTF-8 text into UTF-8:
#     metadata under --metadata-codepage, ICY stream titles from Shoutcast /
#     Icecast radio, CUE sheets, and playlist files. For a music app all four
#     are real -- CUE sheets and ICY titles especially, and old libraries are
#     full of Latin-1, CP1251 and Shift-JIS tags.
#
#     Apple's libc has iconv, so the darwin fork just enables it. Android's
#     does NOT at our API level: bionic only gained iconv(3) at API 28, and
#     this fork builds at API 21 (build.sh) to keep Android 5 through 8
#     working. So mpv's `dependency('iconv')` finds nothing and -Diconv fails.
#
#     The two ways out were: raise minSdk to 28 and lose four Android
#     releases, or bring our own iconv. We bring our own. Owning the engine is
#     exactly so a platform's libc does not decide our feature set -- the
#     alternative was to disable iconv on iOS as well, which would have made
#     the two platforms match by taking a working feature away from one of
#     them.
#
#     Built static, so it lands inside libmpv.so and adds no new DT_NEEDED and
#     no new file to ship. LGPL-2.1-or-later, which is what the rest of this
#     artifact already is.
#
#     --disable-nls: libiconv's own message catalogues are for its CLI tools,
#     which we do not build. --enable-extra-encodings adds the legacy CJK and
#     Cyrillic sets that are the whole reason this is here.

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

../configure \
	CFLAGS=-fPIC CXXFLAGS=-fPIC \
	--host=$ndk_triple \
	--disable-shared \
	--enable-static \
	--disable-nls \
	--disable-rpath \
	--enable-extra-encodings \

make -j$cores
make DESTDIR="$prefix_dir" install
