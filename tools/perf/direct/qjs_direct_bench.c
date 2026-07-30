#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "dtoa.h"
#include "libregexp.h"
#include "quickjs.h"

#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))

static const uint64_t hash_offset = UINT64_C(0xcbf29ce484222325);
static const uint64_t hash_prime = UINT64_C(0x100000001b3);

typedef struct {
    const char *category;
    const char *case_name;
    size_t iterations;
    size_t warmup;
    uint64_t ns_total;
    uint64_t checksum;
    const char *fidelity;
    const char *entry;
    int comparable;
    int checksum_comparable;
    const char *caliber_note;
    int memory_observed;
    int64_t allocation_count_before;
    int64_t allocation_count_after;
    int64_t allocated_bytes_before;
    int64_t allocated_bytes_after;
    const char *allocations_reason;
} BenchResult;

static void fail(const char *message)
{
    fprintf(stderr, "qjs-direct-bench: %s\n", message);
    exit(1);
}

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        fail("clock_gettime(CLOCK_MONOTONIC) failed");
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static uint64_t mix_byte(uint64_t checksum, uint8_t byte)
{
    return (checksum ^ byte) * hash_prime;
}

static uint64_t mix_bytes(uint64_t checksum, const uint8_t *bytes, size_t len)
{
    for (size_t i = 0; i < len; i++)
        checksum = mix_byte(checksum, bytes[i]);
    return checksum;
}

static uint64_t mix_u64(uint64_t checksum, uint64_t value)
{
    for (int i = 0; i < 8; i++) {
        checksum = mix_byte(checksum, (uint8_t)value);
        value >>= 8;
    }
    return checksum;
}

static int64_t read_peak_rss_kb(void)
{
    FILE *file = fopen("/proc/self/status", "r");
    if (!file)
        return -1;
    char line[256];
    int64_t peak_rss_kb = -1;
    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "VmHWM: %" SCNd64 " kB", &peak_rss_kb) == 1)
            break;
    }
    fclose(file);
    return peak_rss_kb;
}

static void emit_result(const BenchResult *result)
{
    double ns_per_op = (double)result->ns_total / (double)result->iterations;
    printf(
        "{\"category\":\"%s\",\"case\":\"%s\",\"engine\":\"qjs\","
        "\"iterations\":%zu,\"warmup\":%zu,\"ns_total\":%" PRIu64 ","
        "\"ns_per_op\":%.6f,\"checksum\":\"%016" PRIx64 "\","
        "\"fidelity\":\"%s\",\"entry\":\"%s\",\"comparable\":%s,"
        "\"checksum_comparable\":%s,\"caliber_note\":\"%s\"",
        result->category,
        result->case_name,
        result->iterations,
        result->warmup,
        result->ns_total,
        ns_per_op,
        result->checksum,
        result->fidelity,
        result->entry,
        result->comparable ? "true" : "false",
        result->checksum_comparable ? "true" : "false",
        result->caliber_note);
    if (result->memory_observed) {
        printf(
            ",\"allocation_count_before\":%" PRId64
            ",\"allocation_count_after\":%" PRId64
            ",\"allocated_bytes_before\":%" PRId64
            ",\"allocated_bytes_after\":%" PRId64
            ",\"allocations_reason\":null",
            result->allocation_count_before,
            result->allocation_count_after,
            result->allocated_bytes_before,
            result->allocated_bytes_after);
    } else {
        printf(
            ",\"allocation_count_before\":null,"
            "\"allocation_count_after\":null,"
            "\"allocated_bytes_before\":null,"
            "\"allocated_bytes_after\":null,"
            "\"allocations_reason\":\"%s\"",
            result->allocations_reason
                ? result->allocations_reason
                : "QuickJS runtime allocation counters unavailable");
    }
    int64_t peak_rss_kb = read_peak_rss_kb();
    if (peak_rss_kb >= 0) {
        printf(
            ",\"peak_rss_kb\":%" PRId64 ",\"peak_rss_reason\":null",
            peak_rss_kb);
    } else {
        printf(
            ",\"peak_rss_kb\":null,"
            "\"peak_rss_reason\":\"unable to read /proc/self/status VmHWM\"");
    }
    printf("}\n");
}

static uint64_t dtoa_loop(size_t iterations, uint64_t checksum)
{
    static const double values[] = {
        0.0,
        -0.0,
        1.0,
        12.5,
        1.0 / 3.0,
        1.2345678901234567,
        1.0e-7,
        1.0e21,
        -9.87654321012345e-120,
    };
    char buffer[128];

    for (size_t i = 0; i < iterations; i++) {
        size_t index = (size_t)((checksum ^ (uint64_t)i) % ARRAY_LEN(values));
        JSDTOATempMem temp_mem;
        int len = js_dtoa(
            buffer,
            values[index],
            10,
            0,
            JS_DTOA_FORMAT_FREE | JS_DTOA_EXP_AUTO,
            &temp_mem);
        if (len < 0 || (size_t)len > sizeof(buffer))
            fail("js_dtoa returned an invalid length");
        checksum = mix_bytes(checksum, (const uint8_t *)buffer, (size_t)len);
        checksum = mix_byte(checksum, 0xff);
    }
    return checksum;
}

static BenchResult run_dtoa(size_t iterations, size_t warmup)
{
    uint64_t warmup_checksum = dtoa_loop(warmup, hash_offset);
    uint64_t start = monotonic_ns();
    uint64_t checksum = dtoa_loop(iterations, warmup_checksum);
    uint64_t elapsed = monotonic_ns() - start;
    return (BenchResult){
        .category = "dtoa",
        .case_name = "mixed-free",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "js_dtoa (dtoa.h)",
        .comparable = 1,
        .checksum_comparable = 1,
        .caliber_note = "radix-10 free format; stack buffer and dtoa temp state are inside each kernel call",
        .allocations_reason = "no QuickJS JSRuntime exists for the dtoa kernel",
    };
}

typedef struct {
    const uint8_t *bytecode;
    const uint8_t *input;
    int input_len;
    uint8_t **captures;
    int capture_count;
    void *opaque;
} RegexpState;

static uint64_t regexp_loop(
    const RegexpState *state,
    size_t iterations,
    uint64_t checksum)
{
    for (size_t i = 0; i < iterations; i++) {
        int result = lre_exec(
            state->captures,
            state->bytecode,
            state->input,
            0,
            state->input_len,
            0,
            state->opaque);
        if (result < 0)
            fail("lre_exec failed");
        checksum = mix_u64(checksum, result == 1 ? 1 : 0);
        if (result == 1) {
            for (int capture = 0; capture < state->capture_count * 2; capture++) {
                uint64_t offset = state->captures[capture]
                    ? (uint64_t)(state->captures[capture] - state->input)
                    : UINT64_MAX;
                checksum = mix_u64(checksum, offset);
            }
        }
    }
    return checksum;
}

static BenchResult run_regexp(size_t iterations, size_t warmup)
{
    static const char pattern[] = "^(?:foo|bar)+[0-9]{2}$";
    static const uint8_t input[] = "foobarfoo42";
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime)
        fail("JS_NewRuntime failed for regexp allocator callbacks");
    JSContext *context = JS_NewContext(runtime);
    if (!context) {
        JS_FreeRuntime(runtime);
        fail("JS_NewContext failed for regexp allocator callbacks");
    }
    int bytecode_len = 0;
    char error_message[256] = {0};
    uint8_t *bytecode = lre_compile(
        &bytecode_len,
        error_message,
        sizeof(error_message),
        pattern,
        strlen(pattern),
        0,
        context);
    if (!bytecode) {
        fprintf(stderr, "qjs-direct-bench: lre_compile failed: %s\n", error_message);
        exit(1);
    }
    int alloc_count = lre_get_alloc_count(bytecode);
    int capture_count = lre_get_capture_count(bytecode);
    if (alloc_count <= 0 || capture_count <= 0)
        fail("unexpected regexp slot count");
    uint8_t **captures = calloc((size_t)alloc_count, sizeof(*captures));
    if (!captures)
        fail("unable to allocate regexp capture slots");

    RegexpState state = {
        .bytecode = bytecode,
        .input = input,
        .input_len = (int)(sizeof(input) - 1),
        .captures = captures,
        .capture_count = capture_count,
        .opaque = context,
    };
    uint64_t warmup_checksum = regexp_loop(&state, warmup, hash_offset);
    JSMemoryUsage memory_before;
    JSMemoryUsage memory_after;
    JS_ComputeMemoryUsage(runtime, &memory_before);
    uint64_t start = monotonic_ns();
    uint64_t checksum = regexp_loop(&state, iterations, warmup_checksum);
    uint64_t elapsed = monotonic_ns() - start;
    JS_ComputeMemoryUsage(runtime, &memory_after);

    free(captures);
    lre_realloc(context, bytecode, 0);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return (BenchResult){
        .category = "regexp",
        .case_name = "exec-latin1",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "lre_exec (libregexp.h)",
        .comparable = 1,
        .checksum_comparable = 1,
        .caliber_note = "compile and capture-slot allocation excluded; timed region executes compiled latin1 regexp",
        .memory_observed = 1,
        .allocation_count_before = memory_before.malloc_count,
        .allocation_count_after = memory_after.malloc_count,
        .allocated_bytes_before = memory_before.malloc_size,
        .allocated_bytes_after = memory_after.malloc_size,
    };
}

typedef struct {
    JSRuntime *runtime;
    JSContext *context;
} QuickJSState;

static QuickJSState quickjs_state_create(void)
{
    QuickJSState state = {
        .runtime = JS_NewRuntime(),
        .context = NULL,
    };
    if (!state.runtime)
        fail("JS_NewRuntime failed");
    state.context = JS_NewContext(state.runtime);
    if (!state.context) {
        JS_FreeRuntime(state.runtime);
        fail("JS_NewContext failed");
    }
    return state;
}

static void quickjs_state_destroy(QuickJSState *state)
{
    JS_FreeContext(state->context);
    JS_FreeRuntime(state->runtime);
    state->context = NULL;
    state->runtime = NULL;
}

static uint64_t property_loop(
    JSContext *context,
    JSValueConst object,
    const JSAtom atoms[4],
    size_t iterations,
    uint64_t checksum)
{
    for (size_t i = 0; i < iterations; i++) {
        size_t index = (size_t)((checksum ^ (uint64_t)i) & 3);
        JSValue value = JS_GetPropertyInternal(
            context,
            object,
            atoms[index],
            object,
            0);
        if (JS_IsException(value))
            fail("JS_GetPropertyInternal threw");
        if (JS_VALUE_GET_TAG(value) != JS_TAG_INT) {
            JS_FreeValue(context, value);
            fail("property lookup did not return an int");
        }
        int32_t int_value = JS_VALUE_GET_INT(value);
        checksum = mix_u64(checksum, (uint32_t)int_value);
        JS_FreeValue(context, value);
    }
    return checksum;
}

static BenchResult run_property_lookup(size_t iterations, size_t warmup)
{
    QuickJSState state = quickjs_state_create();
    JSValue object = JS_NewObject(state.context);
    if (JS_IsException(object))
        fail("JS_NewObject failed");
    static const char *names[] = {"p0", "p1", "p2", "p3"};
    static const int32_t values[] = {11, 23, 37, 53};
    JSAtom atoms[4];
    for (size_t i = 0; i < ARRAY_LEN(atoms); i++) {
        atoms[i] = JS_NewAtom(state.context, names[i]);
        if (atoms[i] == JS_ATOM_NULL)
            fail("JS_NewAtom failed");
        if (JS_SetProperty(
                state.context,
                object,
                atoms[i],
                JS_NewInt32(state.context, values[i])) < 0)
            fail("JS_SetProperty failed");
    }

    uint64_t warmup_checksum =
        property_loop(state.context, object, atoms, warmup, hash_offset);
    JSMemoryUsage memory_before;
    JSMemoryUsage memory_after;
    JS_ComputeMemoryUsage(state.runtime, &memory_before);
    uint64_t start = monotonic_ns();
    uint64_t checksum =
        property_loop(state.context, object, atoms, iterations, warmup_checksum);
    uint64_t elapsed = monotonic_ns() - start;
    JS_ComputeMemoryUsage(state.runtime, &memory_after);

    for (size_t i = 0; i < ARRAY_LEN(atoms); i++)
        JS_FreeAtom(state.context, atoms[i]);
    JS_FreeValue(state.context, object);
    quickjs_state_destroy(&state);
    return (BenchResult){
        .category = "property_lookup",
        .case_name = "own-data",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "true-direct",
        .entry = "JS_GetPropertyInternal (quickjs.h)",
        .comparable = 1,
        .checksum_comparable = 1,
        .caliber_note = "runtime context object atoms and properties built before timing; returned JSValue dup and free are timed",
        .memory_observed = 1,
        .allocation_count_before = memory_before.malloc_count,
        .allocation_count_after = memory_after.malloc_count,
        .allocated_bytes_before = memory_before.malloc_size,
        .allocated_bytes_after = memory_after.malloc_size,
    };
}

static uint64_t typed_array_loop(
    JSContext *context,
    JSValueConst view,
    size_t iterations,
    uint64_t checksum)
{
    for (size_t i = 0; i < iterations; i++) {
        uint32_t index = (uint32_t)((checksum ^ (uint64_t)i) & 1023);
        JSValue value = JS_GetPropertyUint32(context, view, index);
        if (JS_IsException(value))
            fail("JS_GetPropertyUint32 threw");
        if (JS_VALUE_GET_TAG(value) != JS_TAG_INT) {
            JS_FreeValue(context, value);
            fail("typed array get did not return an int");
        }
        int32_t int_value = JS_VALUE_GET_INT(value);
        checksum = mix_u64(checksum, (uint32_t)int_value);
        JS_FreeValue(context, value);
    }
    return checksum;
}

static BenchResult run_typed_array(size_t iterations, size_t warmup)
{
    QuickJSState state = quickjs_state_create();
    JSValue length = JS_NewInt32(state.context, 1024);
    JSValue view = JS_NewTypedArray(
        state.context,
        1,
        &length,
        JS_TYPED_ARRAY_INT32);
    JS_FreeValue(state.context, length);
    if (JS_IsException(view))
        fail("JS_NewTypedArray failed");
    for (uint32_t index = 0; index < 1024; index++) {
        if (JS_SetPropertyUint32(
                state.context,
                view,
                index,
                JS_NewInt32(state.context, (int32_t)(index * 3 + 7))) < 0)
            fail("JS_SetPropertyUint32 failed");
    }

    uint64_t warmup_checksum =
        typed_array_loop(state.context, view, warmup, hash_offset);
    JSMemoryUsage memory_before;
    JSMemoryUsage memory_after;
    JS_ComputeMemoryUsage(state.runtime, &memory_before);
    uint64_t start = monotonic_ns();
    uint64_t checksum =
        typed_array_loop(state.context, view, iterations, warmup_checksum);
    uint64_t elapsed = monotonic_ns() - start;
    JS_ComputeMemoryUsage(state.runtime, &memory_after);

    JS_FreeValue(state.context, view);
    quickjs_state_destroy(&state);
    return (BenchResult){
        .category = "typed_array",
        .case_name = "int32-get",
        .iterations = iterations,
        .warmup = warmup,
        .ns_total = elapsed,
        .checksum = checksum,
        .fidelity = "public-api-proxy",
        .entry = "JS_GetPropertyUint32 (quickjs.h)",
        .comparable = 0,
        .checksum_comparable = 1,
        .caliber_note = "exported property API reaches typed-array access through adapter logic; not the static interpreter fast path",
        .memory_observed = 1,
        .allocation_count_before = memory_before.malloc_count,
        .allocation_count_after = memory_after.malloc_count,
        .allocated_bytes_before = memory_before.malloc_size,
        .allocated_bytes_after = memory_after.malloc_size,
    };
}

static size_t parse_count(const char *text, int allow_zero)
{
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        (!allow_zero && value == 0) || value > SIZE_MAX) {
        fprintf(stderr, "qjs-direct-bench: invalid count: %s\n", text);
        exit(2);
    }
    return (size_t)value;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(
            stderr,
            "usage: qjs-direct-bench <category/case> <iterations> <warmup>\n");
        return 2;
    }
    const char *case_name = argv[1];
    size_t iterations = parse_count(argv[2], 0);
    size_t warmup = parse_count(argv[3], 1);
    BenchResult result;

    if (strcmp(case_name, "dtoa/mixed-free") == 0)
        result = run_dtoa(iterations, warmup);
    else if (strcmp(case_name, "regexp/exec-latin1") == 0)
        result = run_regexp(iterations, warmup);
    else if (strcmp(case_name, "property_lookup/own-data") == 0)
        result = run_property_lookup(iterations, warmup);
    else if (strcmp(case_name, "typed_array/int32-get") == 0)
        result = run_typed_array(iterations, warmup);
    else {
        fprintf(stderr, "qjs-direct-bench: unknown case: %s\n", case_name);
        return 2;
    }

    emit_result(&result);
    return 0;
}
