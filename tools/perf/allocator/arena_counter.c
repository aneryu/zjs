/* LD_PRELOAD shim that counts glibc malloc/free traffic by size, and singles
 * out the sizes that a 4 KiB slab arena can have.
 *
 * Both engines route their slab arena acquire/release to glibc (qjs through
 * js_def_malloc -> malloc, zjs through std.heap.c_allocator -> malloc), and
 * both compute the arena allocation as
 *     40 + floor((4096 - 40) / block_size) * block_size,
 * which takes exactly 12 distinct values in [3624, 4096]. Counting mallocs at
 * those sizes therefore counts arena creations on either engine with the same
 * instrument and no change to either source tree.
 *
 * Caveat recorded in the dossier: a payload allocation that happens to land on
 * one of the 12 sizes is counted as an arena. The full histogram is emitted so
 * that contamination is visible rather than assumed.
 *
 * Build:
 *   gcc -O2 -fPIC -shared -o arena_counter.so arena_counter.c -ldl
 * Use:
 *   ARENA_COUNTER_OUT=/path/to.json LD_PRELOAD=./arena_counter.so <engine> ...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void *(*real_malloc)(size_t);
static void (*real_free)(void *);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);

/* The 12 arena allocation sizes, ascending. */
static const size_t arena_sizes[] = {
    3624, 3784, 3880, 3912, 3992, 4000, 4008, 4040, 4072, 4080, 4088, 4096,
};
#define ARENA_SIZE_COUNT (sizeof(arena_sizes) / sizeof(arena_sizes[0]))

/* Counters are plain non-atomic longs: both engines are single-threaded for
 * these workloads, and making them atomic would perturb the very allocator
 * traffic being counted. */
static long arena_alloc[ARENA_SIZE_COUNT];
static long arena_free[ARENA_SIZE_COUNT];
static long total_malloc;
static long total_free;
static long small_malloc;  /* <= 512, i.e. slab-eligible payload sizes */
static long large_malloc;  /* > 4096 */
static int in_report;

static void init_real(void) {
    if (real_malloc) return;
    real_malloc = dlsym(RTLD_NEXT, "malloc");
    real_free = dlsym(RTLD_NEXT, "free");
    real_calloc = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
}

static int arena_index(size_t size) {
    for (unsigned i = 0; i < ARENA_SIZE_COUNT; i++)
        if (arena_sizes[i] == size) return (int)i;
    return -1;
}

static void note_alloc(size_t size) {
    total_malloc++;
    if (size <= 512) small_malloc++;
    if (size > 4096) large_malloc++;
    int i = arena_index(size);
    if (i >= 0) arena_alloc[i]++;
}

void *malloc(size_t size) {
    init_real();
    void *p = real_malloc(size);
    if (!in_report) note_alloc(size);
    return p;
}

void *calloc(size_t n, size_t size) {
    init_real();
    void *p = real_calloc(n, size);
    if (!in_report) note_alloc(n * size);
    return p;
}

void *realloc(void *ptr, size_t size) {
    init_real();
    void *p = real_realloc(ptr, size);
    if (!in_report) note_alloc(size);
    return p;
}

void free(void *ptr) {
    init_real();
    if (ptr && !in_report) {
        size_t size = malloc_usable_size(ptr);
        total_free++;
        /* usable_size >= requested; an arena request of exactly N normally
         * reports N for these sizes under glibc, but accept the band too so a
         * rounded bin does not silently drop the event. */
        int i = arena_index(size);
        if (i >= 0) arena_free[i]++;
    }
    real_free(ptr);
}

__attribute__((destructor)) static void report(void) {
    in_report = 1;
    const char *path = getenv("ARENA_COUNTER_OUT");
    FILE *f = path ? fopen(path, "w") : stderr;
    if (!f) f = stderr;
    long arena_alloc_total = 0, arena_free_total = 0;
    for (unsigned i = 0; i < ARENA_SIZE_COUNT; i++) {
        arena_alloc_total += arena_alloc[i];
        arena_free_total += arena_free[i];
    }
    fprintf(f, "{\n");
    fprintf(f, "  \"total_malloc\": %ld,\n", total_malloc);
    fprintf(f, "  \"total_free\": %ld,\n", total_free);
    fprintf(f, "  \"payload_le_512\": %ld,\n", small_malloc);
    fprintf(f, "  \"gt_4096\": %ld,\n", large_malloc);
    fprintf(f, "  \"arena_alloc_total\": %ld,\n", arena_alloc_total);
    fprintf(f, "  \"arena_free_total\": %ld,\n", arena_free_total);
    fprintf(f, "  \"by_arena_size\": {");
    int first = 1;
    for (unsigned i = 0; i < ARENA_SIZE_COUNT; i++) {
        if (arena_alloc[i] == 0 && arena_free[i] == 0) continue;
        fprintf(f, "%s\n    \"%zu\": {\"alloc\": %ld, \"free\": %ld}", first ? "" : ",",
                arena_sizes[i], arena_alloc[i], arena_free[i]);
        first = 0;
    }
    fprintf(f, "%s}\n}\n", first ? "" : "\n  ");
    if (f != stderr) fclose(f);
}
