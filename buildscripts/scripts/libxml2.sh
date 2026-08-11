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

# rn-media parity release (#32), item 4: libxml2 2.10.3 -> 2.15.3.
#
# TWO DEAD FLAGS REMOVED at the same time, found by diffing 2.15.3's configure.ac
# against 2.10.3's rather than by a build failure -- autoconf only WARNS about an
# unrecognised --with-*, so these would have sat here being ignored forever:
#
#   --with-tree     the option is gone; the tree API is unconditional now.
#   --without-lzma  the option is gone; lzma support was removed from libxml2
#                   entirely, so there is nothing left to switch off. (It was
#                   already off here anyway via --with-minimum.)
#
# Both are no-ops against 2.15.3, so this changes nothing about the artifact --
# it stops the script asking for things that no longer exist, which is the same
# rule applied to the dead FFmpeg flags in this release.
#
# NOTE for the next bump: the workshop's option-semantics audit covers mpv and
# FFmpeg but NOT the smaller dependencies, which is why this had to be caught by
# hand. Extending it to them is worth doing.
[ -f configure ] || ./autogen.sh

mkdir -p _build$ndk_suffix
cd _build$ndk_suffix

../configure \
    CFLAGS=-fPIC CXXFLAGS=-fPIC \
	--host=$ndk_triple \
    --disable-shared \
    --enable-static \
    --with-minimum \
    --with-threads \

make -j$cores
make DESTDIR="$prefix_dir" install
