# libmpv-android-audio-build

Fork of [`media-kit/libmpv-android-audio-build`](https://github.com/media-kit/libmpv-android-audio-build),
carrying the delta [rn-media](https://github.com/afkcodes/rn-media) needs. All
work lives on the **`rn-media-hls`** branch; releases are tagged
`v<upstream>-rnmedia.N`.

## What this fork changes

| | |
| --- | --- |
| mpv | **0.41.0** (upstream fork base builds 0.35.1) |
| FFmpeg | **8.1.2** (upstream fork base builds 6.0) |
| libplacebo | **6.338.2** — new dependency, mandatory for mpv >= 0.37 |
| NDK | 27.1.12297006 |
| Licence | LGPLv3. No `--enable-gpl`, no `--enable-nonfree`, no new external library. |

Five deltas versus upstream, in the order they were added:

1. **HLS.** `--enable-demuxer=hls --enable-demuxer=mpegts`. Upstream's audio
   flavour builds FFmpeg with `--disable-demuxers` plus an allow-list holding
   neither, so every `.m3u8` failed to demux. `--enable-protocol=hls` was
   already there and is *not* the same thing — that is the deprecated `hls://`
   protocol, and FFmpeg has since deleted it outright while HLS kept working.
2. **Audio filters.** 16 LGPL EQ/DSP filters (`aresample aformat anull volume
   equalizer bass treble lowpass highpass anequalizer superequalizer
   firequalizer acompressor alimiter dynaudnorm loudnorm crossfeed`). Same trap
   one layer up: the filter allow-list held only `overlay` and `equalizer`, so
   mpv's `af=` resolved through `avfilter_get_by_name()` and found nothing.
   `aresample` is not optional — libavfilter auto-inserts it whenever two pads
   disagree on sample format.
3. **A PCM tap** (`patches/mpv/004`) — two properties, `pcm-tap` and
   `pcm-tap-frame`, behind rn-media's audio visualizer. No new exported symbol.
4. **libass removed** (`patches/mpv/003`). mpv has no build switch for it and
   an audio-only build renders no glyphs.
5. **A prefetch hook** (`patches/mpv/006`) — one new client hook,
   `on_prefetch_load`, and a read-only `prefetch-playlist-entry-id` property.
   `--prefetch-playlist` opens the next entry's *raw* filename: `prefetch_next()`
   calls `start_open()` directly and never reaches the hook pipeline, so a client
   that resolves URLs in `on_load` never sees the prefetched entry — and the
   prefetch is discarded at the boundary anyway, because mpv compares the
   prefetched URL against the post-`on_load` one byte-for-byte. Upstream states
   this is permanent ("This does not work with URLs resolved by the `youtube-dl`
   wrapper, and it won't" — `DOCS/man/options.rst`), so gapless network queues
   and resolved/expiring URLs are mutually exclusive without a patch. With it, a
   resolver rewrites the next URL at prefetch time and the prefetched demuxer is
   actually reused. No new exported symbol: hooks ride the existing
   `mpv_hook_add`/`mpv_hook_continue`. The patch header carries the full
   reasoning, including the five places it deliberately diverges from the prior
   art it is based on.

## Building

```sh
cd buildscripts
./download.sh            # SDK/NDK + sources
./rn-media-release.sh    # patch, build 4 ABIs, verify, package, print SHA-256
```

`rn-media-release.sh` refuses to package a `.so` that does not contain a string
only the patched code emits. Verify capabilities in the **shipped artifact**,
never in the build log.

## Testing

```sh
buildscripts/tests/run.sh    # ~15 s once libmpv is built; no device, no emulator
```

The patches under `patches/mpv` are plain C in mpv's core, so they are testable
on the host. `tests/run.sh` re-applies the patch series from pristine, builds a
**native** libmpv from those same sources, and runs `tests/prefetch_hook_test.c`
against it through the public client API — 21 assertions covering patch 006's
three cases (no client registered, a client that continues unchanged, a client
that rewrites the URL), its re-entry guard, and the fact that the playing
track's own state is left alone while the hook is open. It is a real regression
test: removing the guard makes it fail rather than hang.

It needs meson >= 1.3 (mpv 0.41's floor), ninja, pkg-config and dev packages for
ffmpeg and libplacebo >= 6.338. It only ever adds `deps/mpv/_build-linux`; the
Android build directories and `prefix/` are untouched. CI runs it on every push
as the `Host regression tests` job, in parallel with the Android build.

## Notes for the next engine bump

- **mpv is meson-only from 0.37.** `scripts/mpv.sh` documents each waf flag's
  meson spelling; two are not one-to-one (`--enable-lgpl` → `-Dgpl=false`, and
  `--enable-libmpv-shared` needs both `-Dlibmpv=true` *and*
  `--default-library shared`, because the crossfile pins `default_library=static`
  for every other dependency).
- **libplacebo is mandatory from 0.37** and cannot be stripped the way libass
  can — mpv reaches it from core, non-video translation units. It is built with
  every GPU backend disabled.
- **Export control is not automatic.** mpv's waf build generated a version
  script from `libmpv/mpv.def`; 0.37 deleted that file and meson relies only on
  `gnu_symbol_visibility: 'hidden'`, which does nothing for the static archives
  we link. Without `include/mpv.ver` + `--exclude-libs=ALL` the `.so` exports
  4020 symbols instead of 55, FFmpeg's entire surface among them.
- **`patch.sh` runs `git clean -fdq`.** `git reset --hard` alone leaves
  untracked files, and patch 003 adds one, so re-running used to fail.
- Patches upstreamed and therefore deleted: `001.audiotrack_threadsafe` (mpv
  0.41 ships the same fix using `mp_static_mutex`), `005.mpv_dup_node_byte_array`
  (mpv 0.36), and the FFmpeg `dash_base_url_escape` patch (FFmpeg 8.1.2).
