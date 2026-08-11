// CPU A/B for rn-media #30 stage C's -Doptimization=s.
//
// The claim being tested is "-Os on mpv's own tree costs nothing measurable,
// because every hot DSP loop is in FFmpeg, which is a separate build and is
// NOT touched by that flag". This decodes 180 s of FLAC through the heaviest
// filter chain rn-media can build, as fast as the machine allows
// (ao=null + ao-null-untimed), and reports wall time and CPU time.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#include <sys/time.h>

static double now_s(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double cpu_s(void) {
    struct rusage r; getrusage(RUSAGE_SELF, &r);
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6 +
           r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}

static double run_once(const char *path, const char *af) {
    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "ao-null-untimed", "yes");
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "config", "no");
    mpv_set_option_string(h, "idle", "yes");
    mpv_set_option_string(h, "cache", "no");
    if (af) mpv_set_option_string(h, "af", af);
    if (mpv_initialize(h) < 0) { printf("init failed\n"); exit(2); }
    double t0 = now_s();
    const char *cmd[] = {"loadfile", path, NULL};
    mpv_command(h, cmd);
    for (;;) {
        mpv_event *e = mpv_wait_event(h, 10.0);
        if (e->event_id == MPV_EVENT_END_FILE || e->event_id == MPV_EVENT_NONE ||
            e->event_id == MPV_EVENT_SHUTDOWN) break;
    }
    double dt = now_s() - t0;
    mpv_terminate_destroy(h);
    return dt;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/data/local/tmp/rnmedia/long.flac";
    const char *chain =
        "lavfi=[equalizer=f=60:width_type=o:width=2:g=6],"
        "lavfi=[equalizer=f=250:width_type=o:width=2:g=-3],"
        "lavfi=[equalizer=f=1000:width_type=o:width=2:g=4],"
        "lavfi=[equalizer=f=4000:width_type=o:width=2:g=-2],"
        "lavfi=[superequalizer=1b=2:2b=3:3b=4],"
        "lavfi=[firequalizer=gain='if(lt(f,1000),0,-2)'],"
        "lavfi=[crossfeed=strength=0.5],"
        "lavfi=[dynaudnorm=f=200],"
        "lavfi=[alimiter=limit=0.95]";

    struct { const char *name; const char *af; } cases[] = {
        {"decode only        ", NULL},
        {"decode + 9-filter EQ", chain},
    };
    for (unsigned c = 0; c < sizeof cases / sizeof *cases; c++) {
        double best = 1e9, sum = 0; double cpu0 = cpu_s();
        const int N = 3;
        for (int i = 0; i < N; i++) {
            double d = run_once(path, cases[c].af);
            if (d < best) best = d;
            sum += d;
        }
        double cpu = cpu_s() - cpu0;
        printf("  %s  best %.3f s   mean %.3f s   cpu %.3f s   (%.0fx realtime)\n",
               cases[c].name, best, sum / N, cpu / N, 180.0 / best);
        fflush(stdout);
    }
    return 0;
}
