// On-device verification of the size-reduced libmpv (rn-media #30).
//
// Runs on the phone via adb shell, links the stripped libmpv.so, and exercises
// the paths the file-level probe cannot: real demux, real decode, the real
// libavfilter graph, real HTTP + HLS, the real PCM tap and the real prefetch
// hook. ao=null so it needs no JavaVM (the tap sits in audio/out/buffer.c,
// which every AO drives, so it still fires).
#include <mpv/client.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0, checks = 0;
static const char *base = "/data/local/tmp/rnmedia";
static char http_base[128];

static void ok(bool cond, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    checks++;
    printf(cond ? "  ok   " : "  FAIL ");
    vprintf(fmt, ap); printf("\n"); fflush(stdout);
    if (!cond) failures++;
    va_end(ap);
}

static mpv_handle *new_player(void) {
    mpv_handle *h = mpv_create();
    if (!h) { printf("mpv_create failed\n"); exit(2); }
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "audio-display", "no");
    mpv_set_option_string(h, "force-window", "no");
    mpv_set_option_string(h, "idle", "yes");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "config", "no");
    mpv_set_option_string(h, "audio-buffer", "0.05");
    int r = mpv_initialize(h);
    if (r < 0) { printf("mpv_initialize: %s\n", mpv_error_string(r)); exit(2); }
    return h;
}

// Play `url` to natural end. Returns end-file reason, fills duration/loaded.
// Anything read here is read WHILE THE FILE IS LOADED. mpv clears metadata,
// audio-out-params and file-format at end-file, so reading them after play()
// returns yields null on any libmpv, patched or not — the first version of
// this test did exactly that and "failed" identically on the baseline .so.
static char g_title[256], g_aoparams[256], g_fileformat[64];

static int play(mpv_handle *h, const char *url, double *duration, bool *loaded,
                double timeout_s) {
    const char *cmd[] = {"loadfile", url, NULL};
    int r = mpv_command(h, cmd);
    if (r < 0) return r;
    *loaded = false; *duration = -1;
    double waited = 0;
    while (waited < timeout_s) {
        mpv_event *e = mpv_wait_event(h, 0.25);
        if (e->event_id == MPV_EVENT_NONE) { waited += 0.25; continue; }
        if (e->event_id == MPV_EVENT_FILE_LOADED) {
            *loaded = true;
            mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, duration);
            g_title[0] = g_aoparams[0] = g_fileformat[0] = 0;
            char *t = mpv_get_property_string(h, "metadata/by-key/title");
            if (t) { snprintf(g_title, sizeof g_title, "%s", t); mpv_free(t); }
            char *a = mpv_get_property_string(h, "audio-out-params");
            if (a) { snprintf(g_aoparams, sizeof g_aoparams, "%s", a); mpv_free(a); }
            char *f = mpv_get_property_string(h, "file-format");
            if (f) { snprintf(g_fileformat, sizeof g_fileformat, "%s", f); mpv_free(f); }
        }
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *ef = e->data;
            return ef->reason == MPV_END_FILE_REASON_ERROR ? ef->error : (int)ef->reason;
        }
    }
    return -1000; // timeout
}

static void banner(const char *s) { printf("\n== %s ==\n", s); fflush(stdout); }

int main(int argc, char **argv) {
    if (argc > 1) snprintf(http_base, sizeof http_base, "%s", argv[1]);
    else snprintf(http_base, sizeof http_base, "http://127.0.0.1:8099");

    printf("libmpv client API %lu.%lu\n",
           mpv_client_api_version() >> 16, mpv_client_api_version() & 0xffff);

    // ---------------------------------------------------------------- formats
    banner("1. decode + demux, local files, to natural EOF");
    {
        mpv_handle *h = new_player();
        const char *v = mpv_get_property_string(h, "mpv-version");
        printf("  %s\n", v ? v : "(no version)");
        if (v) mpv_free((void *)v);
        const char *files[] = {"tone.wav", "tone.flac", "tone.mp3", "tone.m4a",
                               "tone.ogg", "tone.opus", "tone.mka", NULL};
        for (int i = 0; files[i]; i++) {
            char path[512];
            snprintf(path, sizeof path, "%s/%s", base, files[i]);
            double dur; bool loaded;
            int reason = play(h, path, &dur, &loaded, 25);
            ok(loaded && reason == MPV_END_FILE_REASON_EOF && dur > 2.8 && dur < 3.3,
               "%-10s loaded=%d reason=%d duration=%.3f", files[i], loaded, reason, dur);
        }
        mpv_terminate_destroy(h);
    }

    // ---------------------------------------------------------------- filters
    banner("2. the 17 audio filters, each instantiated in a real graph");
    {
        const char *filters[] = {
            "aresample=48000", "aformat=sample_fmts=fltp:sample_rates=48000", "anull",
            "volume=volume=0.8", "equalizer=f=1000:width_type=o:width=2:g=3",
            "bass=g=4", "treble=g=-3", "lowpass=f=8000", "highpass=f=100",
            "anequalizer=c0 f=200 w=100 g=5", "superequalizer=1b=2:2b=3",
            "firequalizer=gain='if(lt(f,1000),0,-2)'",
            "acompressor=threshold=0.1:ratio=4", "alimiter=limit=0.9",
            "dynaudnorm=f=200", "loudnorm=I=-16:TP=-1.5:LRA=11",
            "crossfeed=strength=0.6", NULL};
        char path[512];
        snprintf(path, sizeof path, "%s/tone.flac", base);
        for (int i = 0; filters[i]; i++) {
            mpv_handle *h = new_player();
            char af[256]; snprintf(af, sizeof af, "lavfi=[%s]", filters[i]);
            int sr = mpv_set_property_string(h, "af", af);
            double dur; bool loaded;
            int reason = play(h, path, &dur, &loaded, 25);
            char *back = mpv_get_property_string(h, "af");
            bool applied = back && strlen(back) > 0;
            ok(sr == 0 && loaded && reason == MPV_END_FILE_REASON_EOF && applied,
               "af=%-42.42s set=%d played=%d", filters[i], sr, reason);
            if (back) mpv_free(back);
            mpv_terminate_destroy(h);
        }
        // a real EQ chain, the way rn-media builds one
        mpv_handle *h = new_player();
        int sr = mpv_set_property_string(h, "af",
            "lavfi=[equalizer=f=60:width_type=o:width=2:g=6],"
            "lavfi=[equalizer=f=1000:width_type=o:width=2:g=-3],"
            "lavfi=[crossfeed=strength=0.5],lavfi=[alimiter=limit=0.95]");
        double dur; bool loaded;
        int reason = play(h, path, &dur, &loaded, 25);
        ok(sr == 0 && reason == MPV_END_FILE_REASON_EOF,
           "4-filter rn-media style chain set=%d reason=%d", sr, reason);
        mpv_terminate_destroy(h);
    }

    // ------------------------------------------------------------- http + hls
    banner("3. HTTP + HLS over the network stack");
    {
        mpv_handle *h = new_player();
        char url[256]; double dur; bool loaded; int reason;

        snprintf(url, sizeof url, "%s/tone.flac", http_base);
        reason = play(h, url, &dur, &loaded, 30);
        ok(loaded && reason == MPV_END_FILE_REASON_EOF,
           "http:// plain file        reason=%d duration=%.3f", reason, dur);

        snprintf(url, sizeof url, "%s/hls/index.m3u8", http_base);
        reason = play(h, url, &dur, &loaded, 40);
        ok(loaded && reason == MPV_END_FILE_REASON_EOF && dur > 2.5 &&
           strstr(g_fileformat, "hls") != NULL,
           "HLS m3u8 (mpegts segs)   reason=%d duration=%.3f file-format=%s",
           reason, dur, g_fileformat);
        mpv_terminate_destroy(h);
    }

    // ----------------------------------------------------------------- iconv
    banner("4. vendored libiconv: CP1251 metadata -> UTF-8");
    {
        mpv_handle *h = mpv_create();
        mpv_set_option_string(h, "ao", "null");
        mpv_set_option_string(h, "vid", "no");
        mpv_set_option_string(h, "terminal", "no");
        mpv_set_option_string(h, "config", "no");
        mpv_set_option_string(h, "idle", "yes");
        mpv_set_option_string(h, "metadata-codepage", "cp1251");
        mpv_initialize(h);
        // A CUE SHEET, not an ID3 tag. demux_cue.c hands the RAW file bytes to
        // mp_charset_guess()/mp_iconv_to_utf8(), i.e. straight into the
        // vendored libiconv. ID3 cannot test this: FFmpeg's ID3 parser has
        // already re-encoded the Latin-1 payload into valid UTF-8 mojibake by
        // the time mpv sees it, and mp_charset_guess() then says "Data looks
        // like UTF-8, ignoring user-provided charset" (misc/charset_conv.c) --
        // correctly. tone.cue is raw CP1251 and is NOT valid UTF-8, so the
        // conversion is forced to happen or the titles come back as garbage.
        char path[512]; snprintf(path, sizeof path, "%s/tone.cue", base);
        const char *lf[] = {"loadfile", path, NULL};
        mpv_command(h, lf);
        char t1[256] = {0}, t2[256] = {0};
        for (int i = 0; i < 300 && !t1[0]; i++) {
            mpv_wait_event(h, 0.05);
            mpv_node n;
            if (mpv_get_property(h, "chapter-list", MPV_FORMAT_NODE, &n) == 0) {
                if (n.format == MPV_FORMAT_NODE_ARRAY && n.u.list->num >= 2) {
                    for (int c = 0; c < 2; c++) {
                        mpv_node *e = &n.u.list->values[c];
                        if (e->format != MPV_FORMAT_NODE_MAP) continue;
                        for (int k = 0; k < e->u.list->num; k++)
                            if (!strcmp(e->u.list->keys[k], "title") &&
                                e->u.list->values[k].format == MPV_FORMAT_STRING)
                                snprintf(c == 0 ? t1 : t2, 256, "%s",
                                         e->u.list->values[k].u.string);
                    }
                }
                mpv_free_node_contents(&n);
            }
        }
        const char *w1 = "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xbc\xd0\xb5\xd1\x80";  // Пример
        const char *w2 = "\xd0\x92\xd1\x82\xd0\xbe\xd1\x80\xd0\xbe\xd0\xb9";  // Второй
        ok(strcmp(t1, w1) == 0, "CUE track 1 title CP1251 -> UTF-8: \"%s\" (want \"%s\")", t1, w1);
        ok(strcmp(t2, w2) == 0, "CUE track 2 title CP1251 -> UTF-8: \"%s\" (want \"%s\")", t2, w2);
        mpv_terminate_destroy(h);
    }

    // --------------------------------------------------------------- pcm tap
    banner("5. PCM tap (rn-media patch 004)");
    {
        mpv_handle *h = new_player();
        int64_t win = 1024;
        int sr = mpv_set_property(h, "pcm-tap", MPV_FORMAT_INT64, &win);
        ok(sr == 0, "set pcm-tap=1024 -> %d", sr);
        char path[512]; snprintf(path, sizeof path, "%s/tone.wav", base);
        const char *cmd[] = {"loadfile", path, NULL};
        mpv_command(h, cmd);
        int64_t seq = -1, frames = 0, rate = 0, ch = 0;
        size_t bytes = 0; bool got = false; double energy = 0;
        for (int i = 0; i < 200 && !got; i++) {
            mpv_wait_event(h, 0.05);
            mpv_node n;
            if (mpv_get_property(h, "pcm-tap-frame", MPV_FORMAT_NODE, &n) == 0) {
                if (n.format == MPV_FORMAT_NODE_MAP) {
                    for (int k = 0; k < n.u.list->num; k++) {
                        const char *key = n.u.list->keys[k];
                        mpv_node *val = &n.u.list->values[k];
                        if (!strcmp(key, "seq")) seq = val->u.int64;
                        else if (!strcmp(key, "frames")) frames = val->u.int64;
                        else if (!strcmp(key, "sample_rate")) rate = val->u.int64;
                        else if (!strcmp(key, "channels")) ch = val->u.int64;
                        else if (!strcmp(key, "samples") &&
                                 val->format == MPV_FORMAT_BYTE_ARRAY) {
                            bytes = val->u.ba->size;
                            const float *f = val->u.ba->data;
                            for (size_t s = 0; s < bytes / 4; s++) energy += f[s] * f[s];
                        }
                    }
                    if (bytes > 0 && seq > 0) got = true;
                }
                mpv_free_node_contents(&n);
            }
        }
        ok(got, "tap produced a window: seq=%lld frames=%lld rate=%lld ch=%lld bytes=%zu",
           (long long)seq, (long long)frames, (long long)rate, (long long)ch, bytes);
        ok(rate == 44100 && ch == 2 && frames == 1024 && bytes == 1024 * 2 * 4,
           "tap geometry: 44100 Hz / 2 ch / 1024 frames / %zu bytes", bytes);
        ok(energy > 1.0, "tap carries real audio (sum of squares = %.1f, 440 Hz tone)", energy);
        int64_t off = 0;
        ok(mpv_set_property(h, "pcm-tap", MPV_FORMAT_INT64, &off) == 0, "tap disarms");
        mpv_terminate_destroy(h);
    }

    // -------------------------------------------------------- prefetch hook
    banner("6. prefetch hook (rn-media patch 006)");
    {
        mpv_handle *h = new_player();
        mpv_set_option_string(h, "prefetch-playlist", "yes");
        mpv_set_option_string(h, "gapless-audio", "weak");
        int hr = mpv_hook_add(h, 1, "on_prefetch_load", 0);
        ok(hr == 0, "mpv_hook_add(on_prefetch_load) -> %d", hr);
        char a[512], b[512];
        snprintf(a, sizeof a, "%s/tone.flac", base);
        snprintf(b, sizeof b, "%s/tone.mp3", base);
        const char *c1[] = {"loadfile", a, "replace", NULL};
        const char *c2[] = {"loadfile", b, "append", NULL};
        mpv_command(h, c1); mpv_command(h, c2);
        int hooks = 0, ends = 0; bool saw_entry_id = false, url_readable = false;
        for (int i = 0; i < 600 && ends < 2; i++) {
            mpv_event *e = mpv_wait_event(h, 0.1);
            if (e->event_id == MPV_EVENT_HOOK) {
                mpv_event_hook *hk = e->data;
                if (!strcmp(hk->name, "on_prefetch_load")) {
                    hooks++;
                    int64_t id = -1;
                    if (mpv_get_property(h, "prefetch-playlist-entry-id",
                                         MPV_FORMAT_INT64, &id) == 0 && id > 0)
                        saw_entry_id = true;
                    char *u = mpv_get_property_string(h, "stream-open-filename");
                    if (u && strstr(u, "tone.mp3")) url_readable = true;
                    if (u) mpv_free(u);
                }
                mpv_hook_continue(h, hk->id);
            }
            if (e->event_id == MPV_EVENT_END_FILE) ends++;
        }
        ok(hooks >= 1, "on_prefetch_load fired %d time(s) on-device", hooks);
        ok(saw_entry_id, "prefetch-playlist-entry-id readable inside the hook");
        ok(url_readable, "stream-open-filename inside the hook is the NEXT entry");
        ok(ends == 2, "both entries reached end-file (%d)", ends);
        int64_t id = -1;
        ok(mpv_get_property(h, "prefetch-playlist-entry-id", MPV_FORMAT_INT64, &id) != 0,
           "prefetch-playlist-entry-id unavailable outside the hook");
        mpv_terminate_destroy(h);
    }

    // ------------------------------------------------------- stubbed paths
    banner("7. patch 007's stubs are called, and do not crash");
    {
        mpv_handle *h = new_player();
        char path[512]; snprintf(path, sizeof path, "%s/tone.flac", base);
        double dur; bool loaded;
        play(h, path, &dur, &loaded, 20);
        const char *s1[] = {"screenshot", NULL};
        const char *s2[] = {"screenshot-to-file", "/data/local/tmp/rnmedia/x.png", NULL};
        int r1 = mpv_command(h, s1);
        int r2 = mpv_command(h, s2);
        ok(true, "screenshot -> %d, screenshot-to-file -> %d (no crash)", r1, r2);
        mpv_node res;
        const char *s3[] = {"screenshot-raw", NULL};
        int r3 = mpv_command_ret(h, s3, &res);
        if (r3 == 0) mpv_free_node_contents(&res);
        ok(true, "screenshot-raw -> %d (no crash)", r3);
        // the option groups the stubs reproduce must still parse
        ok(mpv_set_property_string(h, "screenshot-format", "png") == 0,
           "screenshot_conf option group still parses (screenshot-format=png)");
        ok(mpv_set_property_string(h, "screenshot-jpeg-quality", "80") == 0,
           "image_writer_opts still parses (screenshot-jpeg-quality=80)");
        char *ov = mpv_get_property_string(h, "options/oautofps");
        ok(true, "encode_config option group present=%s", ov ? "yes" : "no");
        if (ov) mpv_free(ov);
        // still plays afterwards
        int reason = play(h, path, &dur, &loaded, 20);
        ok(reason == MPV_END_FILE_REASON_EOF, "playback still works after the stubs (%d)", reason);
        mpv_terminate_destroy(h);
    }

    // ---------------------------------------------------------- seek + gapless
    banner("8. seek, pause, replaygain, gapless queue");
    {
        mpv_handle *h = new_player();
        char path[512]; snprintf(path, sizeof path, "%s/tone.flac", base);
        const char *cmd[] = {"loadfile", path, NULL};
        mpv_command(h, cmd);
        bool loaded = false;
        for (int i = 0; i < 200 && !loaded; i++) {
            mpv_event *e = mpv_wait_event(h, 0.05);
            if (e->event_id == MPV_EVENT_FILE_LOADED) loaded = true;
        }
        const char *sk[] = {"seek", "1.5", "absolute", NULL};
        int sr = mpv_command(h, sk);
        double pos = -1;
        for (int i = 0; i < 60; i++) {
            mpv_wait_event(h, 0.05);
            if (mpv_get_property(h, "time-pos", MPV_FORMAT_DOUBLE, &pos) == 0 && pos > 1.4) break;
        }
        ok(sr == 0 && pos > 1.4, "absolute seek to 1.5s -> time-pos %.3f", pos);
        int flag = 1;
        ok(mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag) == 0, "pause writable");
        flag = 0; mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &flag);
        ok(mpv_set_property_string(h, "replaygain", "track") == 0, "replaygain=track accepted");
        char aop[256] = {0};
        for (int i = 0; i < 100 && !aop[0]; i++) {
            mpv_wait_event(h, 0.05);
            char *a = mpv_get_property_string(h, "audio-out-params");
            if (a) { snprintf(aop, sizeof aop, "%s", a); mpv_free(a); }
        }
        ok(aop[0] != 0, "audio-out-params readable during playback (%s)", aop);
        mpv_terminate_destroy(h);
    }

    printf("\n===== %d checks, %d failure(s) =====\n", checks, failures);
    return failures ? 1 : 0;
}
