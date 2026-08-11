#!/bin/bash -e
#
# rn-media release helper.
#
# Rebuilds mpv from the patched sources, strips, packages the four per-ABI jars
# exactly as a release asset expects them, and — the part that matters —
# verifies the result in the SHIPPED artifact rather than in the build log.
#
# Why this exists: under waf, mpv did not relink libmpv.so when ffmpeg's static
# libs changed, so a rebuilt dependency next to a stale .so looked like a
# successful build and silently shipped the old binary. Every rn-media release
# has to prove its new capability with a string that only the new code emits;
# doing that by hand is how it eventually gets skipped.
#
# THAT TRAP DOES NOT REPRODUCE UNDER MESON — re-tested rather than assumed when
# this fork moved to mpv 0.41 (meson-only since 0.37). ninja names every static
# archive as an explicit input of the link edge, so touching
# prefix/<abi>/lib/libavfilter.a and re-running ninja re-executes
# "Linking target libmpv.so". The resulting .so was byte-identical, because a
# touch changes the mtime and not the content — the point is that the link ran
# at all, which is precisely what waf failed to do.
#
# So `--clean` below is belt-and-braces now rather than load-bearing. It stays:
# it costs one rebuild per release, and what it defends against is a silently
# stale artifact. The real guarantee was never the build system anyway — it is
# the marker check on the SHIPPED binary a few lines down.
#
#   ./rn-media-release.sh                 build + package + verify
#   ./rn-media-release.sh --no-build      package + verify what is in prefix/
#
# Output: rn-media-release/default-<abi>.jar plus the SHA-256 block to paste
# into packages/player/android/libmpv.gradle.

cd "$(dirname "${BASH_SOURCE[0]}")"

ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
NDK_STRIP=$(ls "${ANDROID_HOME:-$HOME/Android/Sdk}"/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip 2>/dev/null || true)
OUT="$PWD/rn-media-release"

# Strings that must be present in every shipped .so. Add one line per feature
# the fork's patches introduce; each must be emitted ONLY by the patched code.
REQUIRED_STRINGS=(
    '[rn-media] pcm-tap window='          # patches/mpv/004.rn_media_pcm_tap.patch
    'pcm-tap-frame'                       # the property table entry itself
    '[rn-media] prefetch hook resolved: ' # patches/mpv/006.rn_media_prefetch_hook.patch
    'on_prefetch_load'                    # the hook name the client registers
    'prefetch-playlist-entry-id'          # the property table entry itself
)

if [ -z "$NDK_STRIP" ]; then
    echo "llvm-strip from NDK 27.1.12297006 not found; set ANDROID_HOME" >&2
    exit 1
fi

if [ "${1:-}" != "--no-build" ]; then
    ./patch.sh
    # --clean is not optional: see the waf note above.
    ./build.sh --clean -n mpv
fi

rm -rf "$OUT"
mkdir -p "$OUT"

for abi in "${ABIS[@]}"; do
    src="$PWD/prefix/$abi/lib/libmpv.so"
    [ -f "$src" ] || { echo "missing $src — run without --no-build" >&2; exit 1; }
    mkdir -p "$OUT/lib/$abi"
    cp "$src" "$OUT/lib/$abi/libmpv.so"
    "$NDK_STRIP" --strip-all "$OUT/lib/$abi/libmpv.so"
done

# Verify the stripped artifact, then package it — in that order, so a jar can
# never exist without having been checked.
for abi in "${ABIS[@]}"; do
    so="$OUT/lib/$abi/libmpv.so"
    for needle in "${REQUIRED_STRINGS[@]}"; do
        if ! strings "$so" | grep -qF -- "$needle"; then
            echo "FAIL: $abi/libmpv.so does not contain '$needle'" >&2
            echo "      the build did not relink; re-run with --clean" >&2
            exit 1
        fi
    done
    echo "ok: $abi carries all ${#REQUIRED_STRINGS[@]} required strings"
done

python3 - "$OUT" "${ABIS[@]}" <<'PY'
import hashlib, os, sys, zipfile

out, abis = sys.argv[1], sys.argv[2:]
digests = {}
for abi in abis:
    so = os.path.join(out, "lib", abi, "libmpv.so")
    jar = os.path.join(out, f"default-{abi}.jar")
    with zipfile.ZipFile(jar, "w", zipfile.ZIP_DEFLATED) as z:
        # Fixed timestamp + mode so two builds of the same source produce two
        # jars that differ only where the .so differs.
        info = zipfile.ZipInfo(f"lib/{abi}/libmpv.so", date_time=(1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        with open(so, "rb") as f:
            z.writestr(info, f.read())
    with open(jar, "rb") as f:
        digests[abi] = hashlib.sha256(f.read()).hexdigest()
    print(f"{abi:13s} so={os.path.getsize(so):9d}  jar={os.path.getsize(jar):9d}")

print("\n// paste into packages/player/android/libmpv.gradle → ext.libmpv.sha256")
print("    sha256    : [")
for abi in abis:
    print("        %-14s: '%s'," % ("'%s'" % abi, digests[abi]))
print("    ],")
PY

echo
echo "assets in $OUT"
