/* LD_PRELOAD counter for audit line P7-30: malloc/free/calloc/realloc counts
 * and byte totals, plus libc memset traffic, measured with the same instrument
 * on both engines and with no source change on either side.
 *
 * Caveat that must be read with any memset number: only memset calls that
 * actually reach libc are visible. Both compilers inline small fixed-size
 * clears, so a zero fill of a 64-byte buffer may not appear here at all. The
 * count is therefore a lower bound and is reported as such.
 *
 * Build:
 *   gcc -O2 -fPIC -shared -o alloc_counter.so alloc_counter.c -ldl
 * Use:
 *   ALLOC_COUNTER_OUT=/path/to.json LD_PRELOAD=./alloc_counter.so <engine> f.js
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *(*real_malloc)(size_t);
static void (*real_free)(void *);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static void *(*real_memset)(void *, int, size_t);

static long n_malloc, n_calloc, n_realloc, n_free, n_memset;
static unsigned long b_malloc, b_calloc, b_realloc, b_free, b_memset;
static int in_report;
/* dlsym itself can allocate on first use; this bootstrap arena keeps the
 * recursion from reaching real_malloc before it is resolved. */
static char boot[65536];
static size_t boot_used;
static int resolving;

static void init_real(void) {
    if (real_malloc) return;
    if (resolving) return;
    resolving = 1;
    real_malloc = dlsym(RTLD_NEXT, "malloc");
    real_free = dlsym(RTLD_NEXT, "free");
    real_calloc = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
    real_memset = dlsym(RTLD_NEXT, "memset");
    resolving = 0;
}

static int from_boot(void *p) {
    return (char *)p >= boot && (char *)p < boot + sizeof(boot);
}

static void *boot_alloc(size_t size) {
    size = (size + 15) & ~(size_t)15;
    if (boot_used + size > sizeof(boot)) return NULL;
    void *p = boot + boot_used;
    boot_used += size;
    return p;
}

void *malloc(size_t size) {
    init_real();
    if (!real_malloc) return boot_alloc(size);
    void *p = real_malloc(size);
    if (!in_report) { n_malloc++; b_malloc += size; }
    return p;
}

void *calloc(size_t n, size_t size) {
    init_real();
    if (!real_calloc) {
        void *p = boot_alloc(n * size);
        if (p && real_memset) real_memset(p, 0, n * size);
        return p;
    }
    void *p = real_calloc(n, size);
    if (!in_report) { n_calloc++; b_calloc += n * size; }
    return p;
}

void *realloc(void *ptr, size_t size) {
    init_real();
    void *p = real_realloc(ptr, size);
    if (!in_report) { n_realloc++; b_realloc += size; }
    return p;
}

void free(void *ptr) {
    init_real();
    if (from_boot(ptr)) return;
    if (ptr && !in_report) { n_free++; b_free += malloc_usable_size(ptr); }
    real_free(ptr);
}

void *memset(void *s, int c, size_t n) {
    init_real();
    if (!in_report) { n_memset++; b_memset += n; }
    return real_memset(s, c, n);
}

__attribute__((destructor)) static void report(void) {
    in_report = 1;
    const char *path = getenv("ALLOC_COUNTER_OUT");
    FILE *f = path ? fopen(path, "w") : stderr;
    if (!f) f = stderr;
    fprintf(f,
            "{\"malloc\": %ld, \"malloc_bytes\": %lu, \"calloc\": %ld, \"calloc_bytes\": %lu,"
            " \"realloc\": %ld, \"realloc_bytes\": %lu, \"free\": %ld, \"free_usable_bytes\": %lu,"
            " \"memset_calls\": %ld, \"memset_bytes\": %lu}\n",
            n_malloc, b_malloc, n_calloc, b_calloc, n_realloc, b_realloc, n_free, b_free,
            n_memset, b_memset);
    if (f != stderr) fclose(f);
}
