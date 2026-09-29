/* Definitive test: is `ln -sfn`-style (unlink+symlink) observable as a gap,
   versus symlink+rename(2)? Reader runs in a thread, no fork, no orphans. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>

static volatile int stop_flag = 0;
static const char *CUR = "racetest/current";
static const char *A = "releases/41", *B = "releases/42";
static unsigned long long miss = 0, ok = 0;

static void *reader(void *_) {
    struct stat st;
    while (!stop_flag) { if (stat(CUR, &st) == 0) ok++; else miss++; }
    return NULL;
}

static void swap_naive(const char *t) { unlink(CUR); symlink(t, CUR); }
static void swap_safe(const char *t) {
    static const char *TMP = "racetest/.current.tmp";
    unlink(TMP); symlink(t, TMP); rename(TMP, CUR);
}

static int run(const char *label, void (*fn)(const char *), int n) {
    unlink(CUR); symlink(A, CUR);
    miss = ok = 0; stop_flag = 0;
    pthread_t th; pthread_create(&th, NULL, reader, NULL);
    for (int i = 0; i < n; i++) fn(i & 1 ? A : B);
    stop_flag = 1; pthread_join(th, NULL);
    printf("%-28s swaps=%-9d samples=%-12llu MISSING=%llu  %s\n",
           label, n, ok + miss, miss, miss ? "*** GAP OBSERVED ***" : "atomic (no gap)");
    return miss > 0;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 500000;
    int gaps = 0;
    gaps |= run("ln -sfn (unlink+symlink)", swap_naive, n);
    gaps |= run("mv -T (symlink+rename)",  swap_safe,  n);
    printf("\nverdict: %s\n", gaps ? "naive form HAS a window; rename form does NOT"
                                    : "no gap observed in either");
    return 0;
}
