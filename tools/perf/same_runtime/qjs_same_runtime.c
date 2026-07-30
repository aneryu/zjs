#include "quickjs.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define MAX_ITERATIONS 1000000U

#ifndef QJS_HARNESS_BUILD_FLAGS
#define QJS_HARNESS_BUILD_FLAGS "unknown"
#endif

#ifdef NDEBUG
#define QJS_HARNESS_NDEBUG_JSON "true"
#else
#define QJS_HARNESS_NDEBUG_JSON "false"
#endif

#ifdef __OPTIMIZE__
#define QJS_HARNESS_BUILD_MODE "optimized"
#else
#define QJS_HARNESS_BUILD_MODE "unoptimized"
#endif

#ifdef JS_NAN_BOXING
#define QJS_HARNESS_NAN_BOXING_JSON "true"
#define QJS_HARNESS_JSVALUE_DESCRIPTION "NaN-boxed"
#else
#define QJS_HARNESS_NAN_BOXING_JSON "false"
#define QJS_HARNESS_JSVALUE_DESCRIPTION "payload-plus-tag"
#endif

typedef enum {
    TEARDOWN_NORMAL,
    TEARDOWN_LEAK_CHECK,
} TeardownMode;

typedef struct {
    const char *case_name;
    const char *source_path;
    size_t iterations;
    size_t warmup;
    TeardownMode teardown_mode;
} Options;

typedef struct {
    uint64_t min_ns;
    uint64_t p25_ns;
    uint64_t median_ns;
    uint64_t p75_ns;
    uint64_t mean_ns;
} SampleStats;

typedef struct {
    uint8_t data[64];
    uint32_t data_len;
    uint64_t bit_len;
    uint32_t state[8];
} Sha256;

static void usage(void);
static void fatal(const char *message);
static Options parse_args(int argc, char **argv);
static uint64_t monotonic_ns(void);
static uint64_t elapsed_ns(uint64_t start);
static int monotonic_resolution_ns(uint64_t *value_out);
static int peak_rss_bytes(uint64_t *value_out);
static char *read_file(const char *path, size_t *length_out);
static int install_standard_globals(JSContext *ctx);
static void dump_exception(JSContext *ctx, const char *stage);
static void fail_js(JSContext *ctx, const char *stage);
static int drain_jobs(JSRuntime *rt, JSContext *fallback_ctx);
static int compare_u64(const void *lhs, const void *rhs);
static uint64_t interpolated_quartile(
    const uint64_t *sorted,
    size_t count,
    size_t numerator
);
static SampleStats calculate_stats(const uint64_t *samples, size_t count);
static void json_string(FILE *output, const char *text);
static void json_optional_u64(FILE *output, int has_value, uint64_t value);
static void write_result(
    const Options *options,
    const char source_sha256[65],
    const char *checksum,
    uint64_t runtime_create_ns,
    uint64_t context_create_ns,
    uint64_t globals_install_ns,
    uint64_t compile_ns,
    uint64_t first_execute_ns,
    uint64_t eval_total_ns,
    uint64_t job_drain_ns,
    int has_destroy_times,
    uint64_t context_destroy_ns,
    uint64_t runtime_destroy_ns,
    size_t compiles,
    size_t top_level_executions,
    const JSMemoryUsage *memory_usage,
    int has_peak_rss,
    uint64_t peak_rss,
    int has_clock_resolution,
    uint64_t clock_resolution_ns,
    const uint64_t *samples,
    const SampleStats *stats
);
static void sha256_init(Sha256 *ctx);
static void sha256_update(Sha256 *ctx, const uint8_t *data, size_t length);
static void sha256_final(Sha256 *ctx, uint8_t hash[32]);
static void sha256_hex(const uint8_t *data, size_t length, char output[65]);

int main(int argc, char **argv)
{
    const Options options = parse_args(argc, argv);
    size_t source_length = 0;
    char *source = read_file(options.source_path, &source_length);
    char source_sha256[65];
    sha256_hex((const uint8_t *)source, source_length, source_sha256);

    uint64_t *samples = calloc(options.iterations, sizeof(*samples));
    if (!samples)
        fatal("unable to allocate timing samples");

    uint64_t start = monotonic_ns();
    JSRuntime *runtime = JS_NewRuntime();
    const uint64_t runtime_create_ns = elapsed_ns(start);
    if (!runtime)
        fatal("JS_NewRuntime failed");

    start = monotonic_ns();
    JSContext *context = JS_NewContextRaw(runtime);
    const uint64_t context_create_ns = elapsed_ns(start);
    if (!context)
        fatal("JS_NewContextRaw failed");

    start = monotonic_ns();
    if (install_standard_globals(context) != 0)
        fail_js(context, "standard-global installation");
    const uint64_t globals_install_ns = elapsed_ns(start);

    size_t compiles = 0;
    size_t top_level_executions = 0;
    const uint64_t eval_total_start = monotonic_ns();
    start = monotonic_ns();
    compiles++;
    JSValue compiled = JS_Eval(
        context,
        source,
        source_length,
        options.source_path,
        JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY
    );
    const uint64_t compile_ns = elapsed_ns(start);
    if (JS_IsException(compiled))
        fail_js(context, "compile");

    start = monotonic_ns();
    top_level_executions++;
    JSValue top_level_result = JS_EvalFunction(context, compiled);
    const uint64_t first_execute_ns = elapsed_ns(start);
    if (JS_IsException(top_level_result))
        fail_js(context, "top-level execution");
    const uint64_t eval_total_ns = elapsed_ns(eval_total_start);
    JS_FreeValue(context, top_level_result);

    uint64_t job_drain_start = monotonic_ns();
    if (drain_jobs(runtime, context) != 0)
        fail_js(context, "post-top-level job drain");
    uint64_t job_drain_ns = elapsed_ns(job_drain_start);

    JSValue global_object = JS_GetGlobalObject(context);
    if (JS_IsException(global_object))
        fail_js(context, "global object lookup");
    JSValue run_function = JS_GetPropertyStr(context, global_object, "run");
    if (JS_IsException(run_function))
        fail_js(context, "run lookup");
    if (!JS_IsFunction(context, run_function))
        fatal("global property 'run' is not callable");

    for (size_t i = 0; i < options.warmup; i++) {
        JSValue result = JS_Call(context, run_function, JS_UNDEFINED, 0, NULL);
        if (JS_IsException(result))
            fail_js(context, "warmup invocation");
        JS_FreeValue(context, result);
    }

    char *result_checksum = NULL;
    for (size_t i = 0; i < options.iterations; i++) {
        const uint64_t execute_start = monotonic_ns();
        JSValue result = JS_Call(context, run_function, JS_UNDEFINED, 0, NULL);
        samples[i] = elapsed_ns(execute_start);
        if (JS_IsException(result))
            fail_js(context, "steady invocation");
        if (i + 1 == options.iterations) {
            const char *text = JS_ToCString(context, result);
            if (!text)
                fail_js(context, "checksum conversion");
            result_checksum = strdup(text);
            JS_FreeCString(context, text);
            if (!result_checksum)
                fatal("unable to allocate checksum");
        }
        JS_FreeValue(context, result);
    }
    if (!result_checksum)
        fatal("no steady invocation produced a checksum");

    job_drain_start = monotonic_ns();
    if (drain_jobs(runtime, context) != 0)
        fail_js(context, "final job drain");
    job_drain_ns += elapsed_ns(job_drain_start);

    const SampleStats stats = calculate_stats(samples, options.iterations);

    JS_FreeValue(context, run_function);
    JS_FreeValue(context, global_object);

    JSMemoryUsage memory_usage;
    JS_ComputeMemoryUsage(runtime, &memory_usage);
    uint64_t peak_rss = 0;
    const int has_peak_rss = peak_rss_bytes(&peak_rss) == 0;
    uint64_t clock_resolution_ns = 0;
    const int has_clock_resolution =
        monotonic_resolution_ns(&clock_resolution_ns) == 0;

    int has_destroy_times = 0;
    uint64_t context_destroy_ns = 0;
    uint64_t runtime_destroy_ns = 0;
    if (options.teardown_mode == TEARDOWN_LEAK_CHECK) {
        start = monotonic_ns();
        JS_FreeContext(context);
        context_destroy_ns = elapsed_ns(start);
        context = NULL;

        start = monotonic_ns();
        JS_FreeRuntime(runtime);
        runtime_destroy_ns = elapsed_ns(start);
        runtime = NULL;
        has_destroy_times = 1;
    } else {
        /*
         * Deliberately mirror short-lived normal CLI behavior: retain the live
         * context/runtime until process exit and let the OS reclaim them.
         */
        has_destroy_times = 0;
    }

    write_result(
        &options,
        source_sha256,
        result_checksum,
        runtime_create_ns,
        context_create_ns,
        globals_install_ns,
        compile_ns,
        first_execute_ns,
        eval_total_ns,
        job_drain_ns,
        has_destroy_times,
        context_destroy_ns,
        runtime_destroy_ns,
        compiles,
        top_level_executions,
        &memory_usage,
        has_peak_rss,
        peak_rss,
        has_clock_resolution,
        clock_resolution_ns,
        samples,
        &stats
    );

    free(result_checksum);
    free(samples);
    free(source);
    return 0;
}

static void usage(void)
{
    fputs(
        "usage: qjs-same-runtime --case NAME --source FILE "
        "[--iterations N] [--warmup N] [--teardown normal|leak-check]\n",
        stderr
    );
}

static void fatal(const char *message)
{
    fprintf(stderr, "error: %s\n", message);
    exit(2);
}

static size_t parse_count(const char *text, const char *label, int allow_zero)
{
    char *end = NULL;
    errno = 0;
    const unsigned long long parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        (!allow_zero && parsed == 0) || parsed > MAX_ITERATIONS) {
        fprintf(
            stderr,
            "error: %s must be %s and at most %u\n",
            label,
            allow_zero ? "non-negative" : "positive",
            MAX_ITERATIONS
        );
        exit(2);
    }
    return (size_t)parsed;
}

static Options parse_args(int argc, char **argv)
{
    Options options = {
        .case_name = NULL,
        .source_path = NULL,
        .iterations = 200,
        .warmup = 20,
        .teardown_mode = TEARDOWN_NORMAL,
    };

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--case") == 0) {
            if (++i >= argc)
                fatal("--case requires a value");
            options.case_name = argv[i];
        } else if (strcmp(arg, "--source") == 0) {
            if (++i >= argc)
                fatal("--source requires a value");
            options.source_path = argv[i];
        } else if (strcmp(arg, "--iterations") == 0) {
            if (++i >= argc)
                fatal("--iterations requires a value");
            options.iterations = parse_count(argv[i], "--iterations", 0);
        } else if (strcmp(arg, "--warmup") == 0) {
            if (++i >= argc)
                fatal("--warmup requires a value");
            options.warmup = parse_count(argv[i], "--warmup", 1);
        } else if (strcmp(arg, "--teardown") == 0) {
            if (++i >= argc)
                fatal("--teardown requires a value");
            if (strcmp(argv[i], "normal") == 0) {
                options.teardown_mode = TEARDOWN_NORMAL;
            } else if (strcmp(argv[i], "leak-check") == 0) {
                options.teardown_mode = TEARDOWN_LEAK_CHECK;
            } else {
                fatal("--teardown must be normal or leak-check");
            }
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            usage();
            exit(0);
        } else {
            fprintf(stderr, "error: unknown argument: %s\n", arg);
            exit(2);
        }
    }

    if (!options.case_name)
        fatal("--case is required");
    if (!options.source_path)
        fatal("--source is required");
    return options;
}

static uint64_t monotonic_ns(void)
{
    struct timespec time_value;
    if (clock_gettime(CLOCK_MONOTONIC, &time_value) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (uint64_t)time_value.tv_sec * UINT64_C(1000000000) +
           (uint64_t)time_value.tv_nsec;
}

static uint64_t elapsed_ns(uint64_t start)
{
    const uint64_t end = monotonic_ns();
    return end > start ? end - start : 0;
}

static int monotonic_resolution_ns(uint64_t *value_out)
{
    struct timespec resolution;
    if (clock_getres(CLOCK_MONOTONIC, &resolution) != 0)
        return -1;
    if (resolution.tv_sec < 0 || resolution.tv_nsec < 0)
        return -1;
    *value_out =
        (uint64_t)resolution.tv_sec * UINT64_C(1000000000) +
        (uint64_t)resolution.tv_nsec;
    return 0;
}

static int peak_rss_bytes(uint64_t *value_out)
{
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0 || usage.ru_maxrss < 0)
        return -1;
    if ((uint64_t)usage.ru_maxrss > UINT64_MAX / UINT64_C(1024))
        return -1;
    *value_out = (uint64_t)usage.ru_maxrss * UINT64_C(1024);
    return 0;
}

static char *read_file(const char *path, size_t *length_out)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "error: unable to open %s: %s\n", path, strerror(errno));
        exit(2);
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fprintf(stderr, "error: unable to seek %s\n", path);
        exit(2);
    }
    const long size = ftell(file);
    if (size < 0) {
        fprintf(stderr, "error: unable to size %s\n", path);
        exit(2);
    }
    if (fseek(file, 0, SEEK_SET) != 0) {
        fprintf(stderr, "error: unable to rewind %s\n", path);
        exit(2);
    }
    char *buffer = malloc((size_t)size + 1);
    if (!buffer)
        fatal("unable to allocate source buffer");
    if (fread(buffer, 1, (size_t)size, file) != (size_t)size) {
        fprintf(stderr, "error: unable to read %s\n", path);
        exit(2);
    }
    if (fclose(file) != 0) {
        fprintf(stderr, "error: unable to close %s\n", path);
        exit(2);
    }
    buffer[size] = '\0';
    *length_out = (size_t)size;
    return buffer;
}

static int install_standard_globals(JSContext *ctx)
{
    return JS_AddIntrinsicBaseObjects(ctx) ||
           JS_AddIntrinsicDate(ctx) ||
           JS_AddIntrinsicEval(ctx) ||
           JS_AddIntrinsicStringNormalize(ctx) ||
           JS_AddIntrinsicRegExp(ctx) ||
           JS_AddIntrinsicJSON(ctx) ||
           JS_AddIntrinsicProxy(ctx) ||
           JS_AddIntrinsicMapSet(ctx) ||
           JS_AddIntrinsicTypedArrays(ctx) ||
           JS_AddIntrinsicPromise(ctx) ||
           JS_AddIntrinsicWeakRef(ctx);
}

static void dump_exception(JSContext *ctx, const char *stage)
{
    JSValue exception = JS_GetException(ctx);
    const char *text = JS_ToCString(ctx, exception);
    if (text) {
        fprintf(stderr, "error: %s failed: %s\n", stage, text);
        JS_FreeCString(ctx, text);
    } else {
        fprintf(stderr, "error: %s failed with a JavaScript exception\n", stage);
    }
    JS_FreeValue(ctx, exception);
}

static void fail_js(JSContext *ctx, const char *stage)
{
    dump_exception(ctx, stage);
    exit(1);
}

static int drain_jobs(JSRuntime *rt, JSContext *fallback_ctx)
{
    for (;;) {
        JSContext *job_ctx = NULL;
        const int status = JS_ExecutePendingJob(rt, &job_ctx);
        if (status == 0)
            return 0;
        if (status < 0) {
            dump_exception(job_ctx ? job_ctx : fallback_ctx, "pending job");
            return -1;
        }
    }
}

static int compare_u64(const void *lhs, const void *rhs)
{
    const uint64_t left = *(const uint64_t *)lhs;
    const uint64_t right = *(const uint64_t *)rhs;
    return (left > right) - (left < right);
}

static uint64_t interpolated_quartile(
    const uint64_t *sorted,
    size_t count,
    size_t numerator
)
{
    const size_t scaled = (count - 1) * numerator;
    const size_t lower = scaled / 4;
    const size_t remainder = scaled % 4;
    if (remainder == 0)
        return sorted[lower];
    const __uint128_t weighted =
        (__uint128_t)sorted[lower] * (4 - remainder) +
        (__uint128_t)sorted[lower + 1] * remainder;
    return (uint64_t)(weighted / 4);
}

static SampleStats calculate_stats(const uint64_t *samples, size_t count)
{
    uint64_t *sorted = malloc(count * sizeof(*sorted));
    if (!sorted)
        fatal("unable to allocate sorted samples");
    memcpy(sorted, samples, count * sizeof(*sorted));
    qsort(sorted, count, sizeof(*sorted), compare_u64);

    __uint128_t sum = 0;
    for (size_t i = 0; i < count; i++)
        sum += sorted[i];
    const size_t midpoint = count / 2;
    const uint64_t median = count % 2
        ? sorted[midpoint]
        : (uint64_t)(((__uint128_t)sorted[midpoint - 1] + sorted[midpoint]) / 2);
    const SampleStats stats = {
        .min_ns = sorted[0],
        .p25_ns = interpolated_quartile(sorted, count, 1),
        .median_ns = median,
        .p75_ns = interpolated_quartile(sorted, count, 3),
        .mean_ns = (uint64_t)(sum / count),
    };
    free(sorted);
    return stats;
}

static void json_string(FILE *output, const char *text)
{
    fputc('"', output);
    for (const unsigned char *cursor = (const unsigned char *)text; *cursor; cursor++) {
        switch (*cursor) {
        case '"':
            fputs("\\\"", output);
            break;
        case '\\':
            fputs("\\\\", output);
            break;
        case '\n':
            fputs("\\n", output);
            break;
        case '\r':
            fputs("\\r", output);
            break;
        case '\t':
            fputs("\\t", output);
            break;
        default:
            if (*cursor < 0x20)
                fprintf(output, "\\u%04x", *cursor);
            else
                fputc(*cursor, output);
            break;
        }
    }
    fputc('"', output);
}

static void json_optional_u64(FILE *output, int has_value, uint64_t value)
{
    if (has_value)
        fprintf(output, "%" PRIu64, value);
    else
        fputs("null", output);
}

static void write_result(
    const Options *options,
    const char source_sha256[65],
    const char *checksum,
    uint64_t runtime_create_ns,
    uint64_t context_create_ns,
    uint64_t globals_install_ns,
    uint64_t compile_ns,
    uint64_t first_execute_ns,
    uint64_t eval_total_ns,
    uint64_t job_drain_ns,
    int has_destroy_times,
    uint64_t context_destroy_ns,
    uint64_t runtime_destroy_ns,
    size_t compiles,
    size_t top_level_executions,
    const JSMemoryUsage *memory_usage,
    int has_peak_rss,
    uint64_t peak_rss,
    int has_clock_resolution,
    uint64_t clock_resolution_ns,
    const uint64_t *samples,
    const SampleStats *stats
)
{
    fputs("{\n  \"engine\": \"qjs\",\n  \"layer\": \"same-runtime\",\n  \"case\": ", stdout);
    json_string(stdout, options->case_name);
    fputs(",\n  \"source_sha256\": ", stdout);
    json_string(stdout, source_sha256);
    fprintf(
        stdout,
        ",\n  \"compiles\": %zu,\n"
        "  \"top_level_executions\": %zu,\n"
        "  \"build\": {\n"
        "    \"mode\": \"%s\",\n"
        "    \"compiler_flags\": ",
        compiles,
        top_level_executions,
        QJS_HARNESS_BUILD_MODE
    );
    json_string(stdout, QJS_HARNESS_BUILD_FLAGS);
    fprintf(
        stdout,
        ",\n    \"ndebug\": %s\n"
        "  },\n"
        "  \"jsvalue_representation\": {\n"
        "    \"size_bytes\": %zu,\n"
        "    \"nan_boxing\": %s,\n"
        "    \"description\": \"%s\"\n"
        "  },\n"
        "  \"clock_monotonic_resolution_ns\": ",
        QJS_HARNESS_NDEBUG_JSON,
        sizeof(JSValue),
        QJS_HARNESS_NAN_BOXING_JSON,
        QJS_HARNESS_JSVALUE_DESCRIPTION
    );
    json_optional_u64(
        stdout,
        has_clock_resolution,
        clock_resolution_ns
    );
    fputs(",\n  \"teardown_mode\": ", stdout);
    json_string(
        stdout,
        options->teardown_mode == TEARDOWN_LEAK_CHECK ? "leak-check" : "normal"
    );
    fprintf(
        stdout,
        ",\n  \"iterations\": %zu,\n  \"warmup\": %zu,\n  \"result_checksum\": ",
        options->iterations,
        options->warmup
    );
    json_string(stdout, checksum);
    fputs(
        ",\n  \"globals_install_note\": "
        "\"JS_NewContextRaw installs basic objects; the remaining JS_NewContext intrinsic sequence is timed separately.\",\n"
        "  \"phase_definitions\": {\n"
        "    \"runtime_create_ns\": \"Create one engine runtime.\",\n"
        "    \"context_create_ns\": \"Create one context; includes standard globals when the engine cannot expose them separately.\",\n"
        "    \"globals_install_ns\": \"Install standard globals separately when the engine API exposes that boundary; otherwise null.\",\n"
        "    \"compile_ns\": \"QuickJS JS_Eval(COMPILE_ONLY) internal timing; not directly comparable to zjs internal parse timing.\",\n"
        "    \"first_execute_ns\": \"QuickJS JS_EvalFunction internal timing; not directly comparable to zjs internal VM-run timing.\",\n"
        "    \"eval_total_ns\": \"Outer wall-clock time around JS_Eval(COMPILE_ONLY) plus JS_EvalFunction, including closure creation and first top-level execution.\",\n"
        "    \"steady_execute\": \"After warmup, each sample times one call to the retained run function; the source is never recompiled.\",\n"
        "    \"job_drain_ns\": \"Sum of pending-job drain time immediately after top-level execution and after all run invocations.\",\n"
        "    \"context_destroy_ns\": \"Destroy the context only in leak-check mode; null in normal mode.\",\n"
        "    \"runtime_destroy_ns\": \"Destroy the runtime only in leak-check mode; null in normal mode.\"\n"
        "  },\n"
        "  \"phases\": {\n",
        stdout
    );
    fprintf(
        stdout,
        "    \"runtime_create_ns\": %" PRIu64 ",\n"
        "    \"context_create_ns\": %" PRIu64 ",\n"
        "    \"globals_install_ns\": %" PRIu64 ",\n"
        "    \"compile_ns\": %" PRIu64 ",\n"
        "    \"first_execute_ns\": %" PRIu64 ",\n"
        "    \"eval_total_ns\": %" PRIu64 ",\n"
        "    \"job_drain_ns\": %" PRIu64 ",\n"
        "    \"context_destroy_ns\": ",
        runtime_create_ns,
        context_create_ns,
        globals_install_ns,
        compile_ns,
        first_execute_ns,
        eval_total_ns,
        job_drain_ns
    );
    json_optional_u64(stdout, has_destroy_times, context_destroy_ns);
    fputs(",\n    \"runtime_destroy_ns\": ", stdout);
    json_optional_u64(stdout, has_destroy_times, runtime_destroy_ns);
    fputs("\n  },\n  \"steady_execute\": {\n    \"samples_ns\": [", stdout);
    for (size_t i = 0; i < options->iterations; i++) {
        if (i != 0)
            fputs(", ", stdout);
        fprintf(stdout, "%" PRIu64, samples[i]);
    }
    fprintf(
        stdout,
        "],\n"
        "    \"min_ns\": %" PRIu64 ",\n"
        "    \"p25_ns\": %" PRIu64 ",\n"
        "    \"median_ns\": %" PRIu64 ",\n"
        "    \"p75_ns\": %" PRIu64 ",\n"
        "    \"mean_ns\": %" PRIu64 "\n"
        "  },\n"
        "  \"resources\": {\n"
        "    \"allocation_count\": %" PRId64 ",\n"
        "    \"allocated_bytes\": %" PRId64 ",\n"
        "    \"memory_used_size\": %" PRId64 ",\n"
        "    \"malloc_count\": %" PRId64 ",\n"
        "    \"malloc_size\": %" PRId64 ",\n"
        "    \"allocation_source\": \"JS_ComputeMemoryUsage JSMemoryUsage\",\n"
        "    \"peak_rss_bytes\": ",
        stats->min_ns,
        stats->p25_ns,
        stats->median_ns,
        stats->p75_ns,
        stats->mean_ns,
        memory_usage->malloc_count,
        memory_usage->malloc_size,
        memory_usage->memory_used_size,
        memory_usage->malloc_count,
        memory_usage->malloc_size
    );
    json_optional_u64(stdout, has_peak_rss, peak_rss);
    fputs(
        ",\n"
        "    \"peak_rss_source\": "
        "\"getrusage(RUSAGE_SELF).ru_maxrss (Linux KiB)\"\n"
        "  }\n"
        "}\n",
        stdout
    );
    if (fflush(stdout) != 0)
        fatal("unable to flush JSON output");
}

static uint32_t rotate_right(uint32_t value, uint32_t count)
{
    return (value >> count) | (value << (32U - count));
}

static void sha256_transform(Sha256 *ctx, const uint8_t block[64])
{
    static const uint32_t constants[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
        0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
        0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
        0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
        0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
        0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
        0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
    };
    uint32_t words[64];
    for (size_t i = 0; i < 16; i++) {
        words[i] = ((uint32_t)block[i * 4] << 24) |
                   ((uint32_t)block[i * 4 + 1] << 16) |
                   ((uint32_t)block[i * 4 + 2] << 8) |
                   (uint32_t)block[i * 4 + 3];
    }
    for (size_t i = 16; i < 64; i++) {
        const uint32_t s0 =
            rotate_right(words[i - 15], 7) ^
            rotate_right(words[i - 15], 18) ^
            (words[i - 15] >> 3);
        const uint32_t s1 =
            rotate_right(words[i - 2], 17) ^
            rotate_right(words[i - 2], 19) ^
            (words[i - 2] >> 10);
        words[i] = words[i - 16] + s0 + words[i - 7] + s1;
    }

    uint32_t a = ctx->state[0];
    uint32_t b = ctx->state[1];
    uint32_t c = ctx->state[2];
    uint32_t d = ctx->state[3];
    uint32_t e = ctx->state[4];
    uint32_t f = ctx->state[5];
    uint32_t g = ctx->state[6];
    uint32_t h = ctx->state[7];
    for (size_t i = 0; i < 64; i++) {
        const uint32_t sigma1 =
            rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
        const uint32_t choice = (e & f) ^ ((~e) & g);
        const uint32_t temp1 = h + sigma1 + choice + constants[i] + words[i];
        const uint32_t sigma0 =
            rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
        const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
        const uint32_t temp2 = sigma0 + majority;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static void sha256_init(Sha256 *ctx)
{
    ctx->data_len = 0;
    ctx->bit_len = 0;
    ctx->state[0] = 0x6a09e667U;
    ctx->state[1] = 0xbb67ae85U;
    ctx->state[2] = 0x3c6ef372U;
    ctx->state[3] = 0xa54ff53aU;
    ctx->state[4] = 0x510e527fU;
    ctx->state[5] = 0x9b05688cU;
    ctx->state[6] = 0x1f83d9abU;
    ctx->state[7] = 0x5be0cd19U;
}

static void sha256_update(Sha256 *ctx, const uint8_t *data, size_t length)
{
    for (size_t i = 0; i < length; i++) {
        ctx->data[ctx->data_len++] = data[i];
        if (ctx->data_len == 64) {
            sha256_transform(ctx, ctx->data);
            ctx->bit_len += 512;
            ctx->data_len = 0;
        }
    }
}

static void sha256_final(Sha256 *ctx, uint8_t hash[32])
{
    uint32_t index = ctx->data_len;
    ctx->data[index++] = 0x80;
    if (index > 56) {
        while (index < 64)
            ctx->data[index++] = 0;
        sha256_transform(ctx, ctx->data);
        index = 0;
    }
    while (index < 56)
        ctx->data[index++] = 0;

    ctx->bit_len += (uint64_t)ctx->data_len * 8;
    for (size_t i = 0; i < 8; i++)
        ctx->data[63 - i] = (uint8_t)(ctx->bit_len >> (i * 8));
    sha256_transform(ctx, ctx->data);

    for (size_t i = 0; i < 8; i++) {
        hash[i * 4] = (uint8_t)(ctx->state[i] >> 24);
        hash[i * 4 + 1] = (uint8_t)(ctx->state[i] >> 16);
        hash[i * 4 + 2] = (uint8_t)(ctx->state[i] >> 8);
        hash[i * 4 + 3] = (uint8_t)ctx->state[i];
    }
}

static void sha256_hex(const uint8_t *data, size_t length, char output[65])
{
    static const char hex[] = "0123456789abcdef";
    uint8_t digest[32];
    Sha256 ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, data, length);
    sha256_final(&ctx, digest);
    for (size_t i = 0; i < sizeof(digest); i++) {
        output[i * 2] = hex[digest[i] >> 4];
        output[i * 2 + 1] = hex[digest[i] & 0x0f];
    }
    output[64] = '\0';
}
