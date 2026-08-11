// Regression test for patches/mpv/006.rn_media_prefetch_hook.patch.
//
// Runs three cases against a REAL libmpv built from the patched tree, on the
// host, with no device and no network — about 15 seconds end to end:
//
//   none         no hook registered            -> must behave like unpatched mpv
//   passthrough  hook registered, continues    -> must behave like unpatched mpv
//   resolve      hook rewrites the URL         -> the prefetch must be REUSED
//
// The playlist is [a.wav, "rnmedia-test://next"]. The second entry has no
// protocol handler, so only a resolver can make it playable: "did the prefetch
// hook work" is therefore directly observable as "did entry 2 play at all",
// and "was the prefetched demuxer reused" is observable as mpv's own
// "Using prefetched/prefetching URL." log line. Nothing here inspects mpv
// internals; every assertion is made through the public client API.
//
// What each case pins down, beyond "it works":
//   * exactly ONE on_prefetch_load per prefetched entry, even though the
//     handler holds the core for 300 ms — that is the re-entry guard
//     (prefetch_next -> process_hooks -> mp_idle -> handle_update_cache ->
//     prefetch_next). Remove the guard and this count runs into the hundreds.
//   * `duration` and `path` still describe the PLAYING track while the hook is
//     open — i.e. the patch does not NULL-mask mpctx->demuxer the way the
//     prior art does.
//   * `prefetch-playlist-entry-id` reads the NEXT entry's id inside the hook
//     and is unavailable outside it.
//   * writing `stream-open-filename` succeeds inside the hook although the
//     playing track's demuxer is attached (M_PROPERTY_ERROR without the patch).
//   * no property-change notification escapes for the prefetch-time write: an
//     observer must not see the resolved URL before entry 2 actually starts.
//
// Build and run: buildscripts/tests/run.sh
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include <mpv/client.h>

#define FAKE_URL "rnmedia-test://next"
#define HOOK_HOLD_MS 300
#define CASE_TIMEOUT_MS 25000

static int failures;

static void ok(bool cond, const char *mode, const char *what)
{
    printf("  %-4s %s / %s\n", cond ? "ok" : "FAIL", mode, what);
    if (!cond)
        failures++;
}

static void msleep(int ms)
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ---------------------------------------------------------------------------
// Test media: 2 s of a tone, 44.1 kHz stereo s16le, written as a plain WAV so
// the test needs no encoder and no fixture files in the repo.
// ---------------------------------------------------------------------------
static bool write_wav(const char *path, double freq)
{
    const int rate = 44100, channels = 2, bits = 16, seconds = 2;
    const int frames = rate * seconds;
    const int data_bytes = frames * channels * (bits / 8);
    FILE *f = fopen(path, "wb");
    if (!f)
        return false;

    unsigned char h[44];
    memcpy(h, "RIFF", 4);
    uint32_t riff = 36 + data_bytes, fmt_len = 16, byte_rate = rate * channels * (bits / 8);
    uint16_t pcm = 1, ch = channels, align = channels * (bits / 8), bps = bits;
    memcpy(h + 4, &riff, 4);
    memcpy(h + 8, "WAVEfmt ", 8);
    memcpy(h + 16, &fmt_len, 4);
    memcpy(h + 20, &pcm, 2);
    memcpy(h + 22, &ch, 2);
    uint32_t r32 = rate;
    memcpy(h + 24, &r32, 4);
    memcpy(h + 28, &byte_rate, 4);
    memcpy(h + 32, &align, 2);
    memcpy(h + 34, &bps, 2);
    memcpy(h + 36, "data", 4);
    uint32_t d32 = data_bytes;
    memcpy(h + 40, &d32, 4);
    fwrite(h, 1, sizeof(h), f);

    for (int i = 0; i < frames; i++) {
        double t = (double)i / rate;
        int16_t v = (int16_t)(12000.0 * sin(2.0 * 3.14159265358979 * freq * t));
        fwrite(&v, 2, 1, f);
        fwrite(&v, 2, 1, f);
    }
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------

struct result {
    int hook_prefetch, hook_load;
    bool saw_prefetching;       // mpv logged "Prefetching: <url>"
    bool saw_marker;            // our patch logged "[rn-media] prefetch hook resolved:"
    bool saw_using_prefetched;  // mpv logged "Using prefetched/prefetching URL."
    bool saw_open_done_b;       // the opener actually opened the RESOLVED url
    bool set_ok;                // the in-hook property write was accepted

    // Observed from inside on_prefetch_load.
    bool pf_sof_is_next;        // stream-open-filename == the next entry's URL
    bool pf_path_is_playing;    // path still == the PLAYING file
    bool pf_duration_available; // duration of the PLAYING track still readable
    int64_t pf_entry_id;        // prefetch-playlist-entry-id inside the hook
    bool id_leaked_outside;     // ...readable during on_load (it must not be)

    bool sof_b_before_entry2;   // observer saw the resolved URL too early
    bool entry2_started, entry2_ended;
    int entry2_error;
};

static char *getstr(mpv_handle *ctx, const char *name)
{
    char *v = NULL;
    return mpv_get_property(ctx, name, MPV_FORMAT_STRING, &v) < 0 ? NULL : v;
}

static bool streq(const char *a, const char *b)
{
    return a && b && strcmp(a, b) == 0;
}

static void run_case(const char *mode, const char *file_a, const char *file_b,
                     struct result *r)
{
    memset(r, 0, sizeof(*r));
    r->pf_entry_id = -1;

    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        fprintf(stderr, "mpv_create failed\n");
        exit(1);
    }
    mpv_set_option_string(ctx, "terminal", "no");
    // Hermetic: a developer's ~/.config/mpv/mpv.conf must not be able to change
    // what this test measures (prefetch-playlist and the AO in particular).
    mpv_set_option_string(ctx, "config", "no");
    mpv_set_option_string(ctx, "vid", "no");
    mpv_set_option_string(ctx, "ao", "null");
    mpv_set_option_string(ctx, "audio-display", "no");
    mpv_set_option_string(ctx, "idle", "yes");
    mpv_set_option_string(ctx, "prefetch-playlist", "yes");
    if (mpv_initialize(ctx) < 0) {
        fprintf(stderr, "mpv_initialize failed\n");
        exit(1);
    }
    mpv_request_log_messages(ctx, "v");
    mpv_observe_property(ctx, 0, "stream-open-filename", MPV_FORMAT_STRING);

    bool hooked = strcmp(mode, "none") != 0;
    if (hooked) {
        mpv_hook_add(ctx, 1, "on_prefetch_load", 0);
        mpv_hook_add(ctx, 2, "on_load", 0);
    }

    const char *load_a[] = {"loadfile", file_a, "replace", NULL};
    const char *load_b[] = {"loadfile", FAKE_URL, "append", NULL};
    mpv_command(ctx, load_a);
    mpv_command(ctx, load_b);

    int64_t want_id = -1;
    mpv_get_property(ctx, "playlist/1/id", MPV_FORMAT_INT64, &want_id);

    // A WALL-CLOCK deadline, deliberately: counting idle ticks would never
    // expire when the player is flooding us with events, which is exactly what
    // a broken re-entry guard does. A regression must fail, not hang.
    int64_t deadline = now_ms() + CASE_TIMEOUT_MS;
    int ended = 0;
    while (now_ms() < deadline && ended < 2) {
        mpv_event *ev = mpv_wait_event(ctx, 0.25);
        if (ev->event_id == MPV_EVENT_NONE)
            continue;
        switch (ev->event_id) {
        case MPV_EVENT_LOG_MESSAGE: {
            mpv_event_log_message *m = ev->data;
            if (strstr(m->text, "Prefetching: "))
                r->saw_prefetching = true;
            if (strstr(m->text, "[rn-media] prefetch hook resolved: "))
                r->saw_marker = true;
            if (strstr(m->text, "Using prefetched"))
                r->saw_using_prefetched = true;
            if (strstr(m->text, "Opening done: ") && strstr(m->text, file_b))
                r->saw_open_done_b = true;
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE: {
            mpv_event_property *p = ev->data;
            if (p->format == MPV_FORMAT_STRING && p->data) {
                char *val = *(char **)p->data;
                if (streq(val, file_b) && !r->entry2_started)
                    r->sof_b_before_entry2 = true;
            }
            break;
        }
        case MPV_EVENT_START_FILE: {
            mpv_event_start_file *sf = ev->data;
            if (sf->playlist_entry_id == want_id)
                r->entry2_started = true;
            break;
        }
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *ef = ev->data;
            if (ef->playlist_entry_id == want_id) {
                r->entry2_ended = true;
                r->entry2_error = ef->error;
            }
            ended++;
            break;
        }
        case MPV_EVENT_HOOK: {
            mpv_event_hook *h = ev->data;
            bool is_prefetch = strcmp(h->name, "on_prefetch_load") == 0;
            char *sof = getstr(ctx, "stream-open-filename");
            int64_t id = -1;
            int id_err = mpv_get_property(ctx, "prefetch-playlist-entry-id",
                                          MPV_FORMAT_INT64, &id);
            if (is_prefetch) {
                r->hook_prefetch++;
                char *path = getstr(ctx, "path");
                double dur = 0;
                r->pf_sof_is_next = streq(sof, FAKE_URL);
                r->pf_path_is_playing = streq(path, file_a);
                r->pf_duration_available =
                    mpv_get_property(ctx, "duration", MPV_FORMAT_DOUBLE, &dur) >= 0 &&
                    dur > 0;
                r->pf_entry_id = id_err >= 0 ? id : -1;
                mpv_free(path);
                // Hold the core on the FIRST invocation so mp_idle() ->
                // handle_update_cache() -> prefetch_next() is re-entered while
                // this hook is open. That is the whole point of the hold, and
                // holding again would only slow a run that is already failing.
                if (r->hook_prefetch == 1)
                    msleep(HOOK_HOLD_MS);
                // Runaway == the re-entry guard is gone. Stop now so the run
                // ends in seconds with a failed assertion instead of grinding
                // to the deadline.
                if (r->hook_prefetch > 20)
                    deadline = 0;
            } else {
                r->hook_load++;
                if (id_err >= 0)
                    r->id_leaked_outside = true;
            }

            if (strcmp(mode, "resolve") == 0 && streq(sof, FAKE_URL)) {
                int e = mpv_set_property_string(ctx, "stream-open-filename", file_b);
                if (is_prefetch)
                    r->set_ok = e >= 0;
            }
            mpv_free(sof);
            mpv_hook_continue(ctx, h->id);
            break;
        }
        default:
            break;
        }
    }
    mpv_terminate_destroy(ctx);

    printf("[%s] on_prefetch_load=%d on_load=%d entry2(started=%d ended=%d error=%d)"
           " marker=%d reused=%d\n",
           mode, r->hook_prefetch, r->hook_load, r->entry2_started, r->entry2_ended,
           r->entry2_error, r->saw_marker, r->saw_using_prefetched);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : ".";
    char file_a[4096], file_b[4096];
    snprintf(file_a, sizeof(file_a), "%s/prefetch_hook_a.wav", dir);
    snprintf(file_b, sizeof(file_b), "%s/prefetch_hook_b.wav", dir);
    if (!write_wav(file_a, 440.0) || !write_wav(file_b, 660.0)) {
        fprintf(stderr, "could not write test media into %s\n", dir);
        return 1;
    }

    struct result none, pass, res;
    run_case("none", file_a, file_b, &none);
    run_case("passthrough", file_a, file_b, &pass);
    run_case("resolve", file_a, file_b, &res);

    // 1. No client registered: identical to unpatched mpv. The raw URL is
    //    prefetched, fails, and entry 2 never plays.
    ok(none.hook_prefetch == 0 && none.hook_load == 0, "none", "no hooks fire");
    ok(none.saw_prefetching, "none", "mpv still prefetches the raw URL");
    ok(!none.saw_marker, "none", "patched path not taken");
    ok(!none.saw_using_prefetched, "none", "no prefetch reuse");
    ok(none.entry2_ended && none.entry2_error != 0, "none", "unresolvable entry fails");

    // 2. Registered but passive: also identical to unpatched mpv, and the
    //    hook's view of the world is the designed one.
    ok(pass.hook_prefetch == 1, "passthrough", "exactly one on_prefetch_load (re-entry guard)");
    ok(pass.hook_load == 2, "passthrough", "on_load unaffected (once per played entry)");
    ok(pass.pf_sof_is_next, "passthrough", "stream-open-filename is the NEXT entry's URL");
    ok(pass.pf_path_is_playing, "passthrough", "path still describes the PLAYING track");
    ok(pass.pf_duration_available, "passthrough", "duration still readable (demuxer not masked)");
    ok(pass.pf_entry_id > 0, "passthrough", "prefetch-playlist-entry-id readable in hook");
    ok(!pass.id_leaked_outside, "passthrough", "...and unavailable outside it");
    ok(!pass.saw_using_prefetched && pass.entry2_error != 0, "passthrough",
       "continuing unchanged behaves like unpatched");

    // 3. Resolving: the prefetch opens the RESOLVED url and the boundary reuses it.
    ok(res.hook_prefetch == 1, "resolve", "exactly one on_prefetch_load (re-entry guard)");
    ok(res.hook_load == 2, "resolve", "on_load once per played entry");
    ok(res.set_ok, "resolve", "stream-open-filename writable inside the hook");
    ok(res.saw_marker, "resolve", "patch resolved the prefetch URL");
    ok(res.saw_open_done_b, "resolve", "opener opened the RESOLVED url");
    ok(res.saw_using_prefetched, "resolve", "prefetched demuxer REUSED at the boundary");
    ok(res.entry2_ended && res.entry2_error == 0, "resolve", "entry 2 played to natural end");
    ok(!res.sof_b_before_entry2, "resolve",
       "no property-change notification escapes for the prefetch-time write");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
