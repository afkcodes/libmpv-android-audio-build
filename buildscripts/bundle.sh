#!/bin/bash
# Fail on the FIRST error, and treat an unset variable as an error.
#
# This script had neither. It ran ./download.sh ./patch.sh ./build.sh and then
# copied prefix/<abi>/usr/local/lib/libmpv.so into the jars -- so when the mpv
# build failed, the copy failed too, the `zip` still succeeded on whatever was
# left, and the job exited 0. CI reported SUCCESS for four consecutive commits
# while shipping jars that contained only libmediakitandroidhelper.so and no
# engine at all (480 KB artifacts where a real build produces 15 MB).
#
# A build that cannot fail cannot be a check. See the assertion at the bottom
# too: exiting non-zero is necessary but not sufficient, because the thing that
# went wrong here was a MISSING FILE, not a non-zero exit.
set -euo pipefail

# --------------------------------------------------

if [ ! -f "deps" ]; then
  sudo rm -r deps
fi
if [ ! -f "prefix" ]; then
  sudo rm -r prefix
fi

./download.sh
./patch.sh
./build.sh

zip -r debug-symbols-default.zip prefix/*/lib

# The NDK version is pinned in ONE place, include/depinfo.sh. It used to be
# written out again in each strip path below, so a bump silently left this
# script pointing at an NDK that download-sdk.sh no longer installs.
. ./include/depinfo.sh
STRIP=./sdk/android-sdk-linux/ndk/$v_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  $STRIP --strip-all prefix/$abi/usr/local/lib/libmpv.so
done

# --------------------------------------------------

cd deps/media-kit-android-helper

sudo chmod +x gradlew
./gradlew assembleRelease

unzip -o app/build/outputs/apk/release/app-release.apk -d app/build/outputs/apk/release

cp ../../prefix/arm64-v8a/usr/local/lib/libmpv.so      app/build/outputs/apk/release/lib/arm64-v8a
cp ../../prefix/armeabi-v7a/usr/local/lib/libmpv.so    app/build/outputs/apk/release/lib/armeabi-v7a
cp ../../prefix/x86/usr/local/lib/libmpv.so            app/build/outputs/apk/release/lib/x86
cp ../../prefix/x86_64/usr/local/lib/libmpv.so         app/build/outputs/apk/release/lib/x86_64

cd app/build/outputs/apk/release

zip -r default-arm64-v8a.jar      lib/arm64-v8a/*.so
zip -r default-armeabi-v7a.jar    lib/armeabi-v7a/*.so
zip -r default-x86.jar            lib/x86/*.so
zip -r default-x86_64.jar         lib/x86_64/*.so

# A jar without libmpv.so in it is not a release artifact, whatever the exit
# codes said. This is the assertion that would have caught the four green-but-
# empty builds immediately.
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
  jar="default-$abi.jar"
  if ! unzip -l "$jar" | grep -q "lib/$abi/libmpv.so"; then
    printf >&2 '\e[1;31m%s\e[m\n' "$jar does not contain lib/$abi/libmpv.so -- the engine did not build"
    unzip -l "$jar" >&2
    exit 1
  fi
done
echo "All four jars contain libmpv.so."

md5sum *.jar
