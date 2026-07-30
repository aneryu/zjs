/* LD_PRELOAD control for audit line P7-30.
 *
 * zjs's JSRuntime.requestGCForProcessMemoryPressure() reads /proc/self/statm
 * and probes two cgroup limit files on every external-memory report, i.e. on
 * every ArrayBuffer backing-store allocation. Under the default `balanced` GC
 * policy every gate that consumes those two numbers is statically disabled
 * (rss_soft_limit / rss_hard_limit are null, both cgroup ratios are 0), so
 * processMemoryRequest() always returns null.
 *
 * This shim makes the probe free without touching src/: openat() on any of the
 * three paths returns -1/ENOENT without issuing a syscall, so currentRssBytes()
 * and cgroupLimitBytes() both return 0 and processMemoryRequest(0, 0) returns
 * null -- exactly the decision the unmodified engine reaches on this host. It
 * is therefore a semantics-preserving "what if the probe cost nothing" control,
 * not a behaviour change.
 *
 * The counters make the control auditable: PROBE_BLOCK_OUT receives how many
 * calls were suppressed, so a case that reports 0 suppressions is proof that
 * the case never probed in the first place.
 *
 * Build:
 *   gcc -O2 -fPIC -shared -o probe_block.so probe_block.c -ldl
 * Use:
 *   PROBE_BLOCK_OUT=/path/to.json LD_PRELOAD=./probe_block.so zjs case.js
 * Set PROBE_BLOCK_PASSIVE=1 to count without suppressing (the A side of the A/B).
 * Set PROBE_BLOCK_ONLY=statm or PROBE_BLOCK_ONLY=cgroup to suppress just one of
 * the two halves, which separates the cost of the /proc/self/statm read from the
 * cost of the two always-failing cgroup opens.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* zjs's Zig std links glibc's openat64, not openat, so both are interposed:
 * `nm -D zjs` shows `U openat64@GLIBC_2.17`. Interposing only openat silently
 * counts nothing, which is how this was caught. */
static int (*real_openat)(int, const char *, int, ...);
static int (*real_openat64)(int, const char *, int, ...);
static long blocked_statm, blocked_cgroup_v2, blocked_cgroup_v1;
static int passive = -1;
static int only_statm, only_cgroup;
static int in_report;

static void init_real(void) {
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    if (!real_openat64) real_openat64 = dlsym(RTLD_NEXT, "openat64");
    if (passive < 0) {
        passive = getenv("PROBE_BLOCK_PASSIVE") ? 1 : 0;
        const char *only = getenv("PROBE_BLOCK_ONLY");
        if (only && !strcmp(only, "statm")) only_statm = 1;
        else if (only && !strcmp(only, "cgroup")) only_cgroup = 1;
    }
}

static int classify_and_maybe_block(const char *path) {
    if (path && !in_report) {
        long *slot = 0;
        int is_statm = 0;
        if (!strcmp(path, "/proc/self/statm")) { slot = &blocked_statm; is_statm = 1; }
        else if (!strcmp(path, "/sys/fs/cgroup/memory.max")) slot = &blocked_cgroup_v2;
        else if (!strcmp(path, "/sys/fs/cgroup/memory/memory.limit_in_bytes")) slot = &blocked_cgroup_v1;
        if (slot) {
            (*slot)++;
            if (passive) return 0;
            if (only_statm) return is_statm;
            if (only_cgroup) return !is_statm;
            return 1;
        }
    }
    return 0;
}

static mode_t va_mode(int flags, va_list ap) {
    if (flags & (O_CREAT | O_TMPFILE)) return va_arg(ap, mode_t);
    return 0;
}

int openat(int dirfd, const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    mode_t mode = va_mode(flags, ap);
    va_end(ap);
    init_real();
    if (classify_and_maybe_block(path)) {
        errno = ENOENT;
        return -1;
    }
    return real_openat(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    mode_t mode = va_mode(flags, ap);
    va_end(ap);
    init_real();
    if (classify_and_maybe_block(path)) {
        errno = ENOENT;
        return -1;
    }
    return real_openat64(dirfd, path, flags, mode);
}

__attribute__((destructor)) static void report(void) {
    in_report = 1;
    const char *out = getenv("PROBE_BLOCK_OUT");
    FILE *f = out ? fopen(out, "w") : 0;
    if (!f) return;
    fprintf(f,
            "{\"passive\": %d, \"statm\": %ld, \"cgroup_v2\": %ld, \"cgroup_v1\": %ld, \"total\": %ld}\n",
            passive, blocked_statm, blocked_cgroup_v2, blocked_cgroup_v1,
            blocked_statm + blocked_cgroup_v2 + blocked_cgroup_v1);
    fclose(f);
}
