#!/bin/bash -e

PATCHES=(patches/*)
ROOT=$(pwd)

for dep_path in "${PATCHES[@]}"; do
    if [ -d "$dep_path" ]; then
        patches=($dep_path/*)
        dep=$(echo $dep_path |cut -d/ -f 2)
        cd deps/$dep
        echo Patching $dep
        git reset --hard
        # `git reset --hard` reverts tracked files and leaves untracked ones
        # alone, which was fine while every patch only modified existing files.
        # 003.mpv_remove_libass.patch ADDS sub/stub_libass.c, and a second run
        # then dies with "already exists in working directory" — i.e. patch.sh
        # stopped being idempotent the moment a patch created a file.
        #
        # `-fd` and not `-fdx`: without -x, git leaves ignored paths alone, so
        # the meson _build* directories survive and only genuinely new files
        # (the stub) are removed.
        git clean -fdq
        for patch in "${patches[@]}"; do
            echo Applying $patch
            git apply "$ROOT/$patch"
        done
        cd $ROOT
    fi
done

exit 0
