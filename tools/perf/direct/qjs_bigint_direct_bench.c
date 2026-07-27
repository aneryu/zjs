#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifndef CONFIG_VERSION
#define CONFIG_VERSION "2026-06-04"
#endif

/*
 * This harness intentionally includes the pinned implementation translation
 * unit so its static js_bigint_mul kernel is callable. It is compiled without
 * libquickjs.a; dtoa/libregexp/libunicode/cutils are linked as source files.
 */
#include "quickjs.c"

static const uint64_t direct_hash_offset = UINT64_C(0xcbf29ce484222325);
static const uint64_t direct_hash_prime = UINT64_C(0x100000001b3);

static void direct_fail(const char *message)
{
    fprintf(stderr, "qjs-bigint-direct-bench: %s\n", message);
    exit(1);
}

static uint64_t direct_monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        direct_fail("clock_gettime(CLOCK_MONOTONIC) failed");
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

static uint64_t direct_mix_byte(uint64_t checksum, uint8_t byte)
{
    return (checksum ^ byte) * direct_hash_prime;
}

static uint64_t direct_mix_u64(uint64_t checksum, uint64_t value)
{
    for (int i = 0; i < 8; i++) {
        checksum = direct_mix_byte(checksum, (uint8_t)value);
        value >>= 8;
    }
    return checksum;
}

static int64_t direct_read_peak_rss_kb(void)
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

static JSValue direct_eval_value(JSContext *context, const char *source)
{
    JSValue value = JS_Eval(
        context,
        source,
        strlen(source),
        "<direct-bigint-setup>",
        JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value))
        direct_fail("JS_Eval failed during operand setup");
    return value;
}

static uint64_t direct_bigint_loop(
    JSContext *context,
    const JSBigInt *lhs,
    const JSBigInt *rhs,
    size_t iterations,
    uint64_t checksum)
{
    for (size_t i = 0; i < iterations; i++) {
        const JSBigInt *first;
        const JSBigInt *second;
        if (((checksum ^ (uint64_t)i) & 1) == 0) {
            first = lhs;
            second = rhs;
        } else {
            first = rhs;
            second = lhs;
        }
        JSBigInt *product = js_bigint_mul(context, first, second);
        if (!product)
            direct_fail("js_bigint_mul failed");
        uint64_t low_limb = product->tab[0];
        checksum = direct_mix_u64(checksum, low_limb);
        JS_FreeValue(context, JS_MKPTR(JS_TAG_BIG_INT, product));
    }
    return checksum;
}

static size_t direct_parse_count(const char *text, int allow_zero)
{
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        (!allow_zero && value == 0) || value > SIZE_MAX) {
        fprintf(stderr, "qjs-bigint-direct-bench: invalid count: %s\n", text);
        exit(2);
    }
    return (size_t)value;
}

int main(int argc, char **argv)
{
    if (argc != 4 || strcmp(argv[1], "bigint/mul-multilimb") != 0) {
        fprintf(
            stderr,
            "usage: qjs-bigint-direct-bench bigint/mul-multilimb "
            "<iterations> <warmup>\n");
        return 2;
    }
    size_t iterations = direct_parse_count(argv[2], 0);
    size_t warmup = direct_parse_count(argv[3], 1);

    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime)
        direct_fail("JS_NewRuntime failed");
    JSContext *context = JS_NewContext(runtime);
    if (!context) {
        JS_FreeRuntime(runtime);
        direct_fail("JS_NewContext failed");
    }
    JSValue lhs_value = direct_eval_value(
        context,
        "123456789012345678901234567890123456789n");
    JSValue rhs_value = direct_eval_value(
        context,
        "98765432109876543210987654321n");
    if (JS_VALUE_GET_TAG(lhs_value) != JS_TAG_BIG_INT ||
        JS_VALUE_GET_TAG(rhs_value) != JS_TAG_BIG_INT)
        direct_fail("operand setup did not produce heap BigInts");
    const JSBigInt *lhs = JS_VALUE_GET_PTR(lhs_value);
    const JSBigInt *rhs = JS_VALUE_GET_PTR(rhs_value);

    uint64_t warmup_checksum = direct_bigint_loop(
        context,
        lhs,
        rhs,
        warmup,
        direct_hash_offset);
    JSMemoryUsage memory_before;
    JSMemoryUsage memory_after;
    JS_ComputeMemoryUsage(runtime, &memory_before);
    uint64_t start = direct_monotonic_ns();
    uint64_t checksum = direct_bigint_loop(
        context,
        lhs,
        rhs,
        iterations,
        warmup_checksum);
    uint64_t elapsed = direct_monotonic_ns() - start;
    JS_ComputeMemoryUsage(runtime, &memory_after);

    JS_FreeValue(context, rhs_value);
    JS_FreeValue(context, lhs_value);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);

    int64_t peak_rss_kb = direct_read_peak_rss_kb();
    printf(
        "{\"category\":\"bigint\",\"case\":\"mul-multilimb\","
        "\"engine\":\"qjs\",\"iterations\":%zu,\"warmup\":%zu,"
        "\"ns_total\":%" PRIu64 ",\"ns_per_op\":%.6f,"
        "\"checksum\":\"%016" PRIx64 "\",\"fidelity\":\"true-direct\","
        "\"entry\":\"js_bigint_mul (quickjs.c included TU)\","
        "\"comparable\":true,\"checksum_comparable\":true,"
        "\"caliber_note\":\"operands parsed before timing; static kernel "
        "allocation multiplication low-limb consume and JSValue free are timed\","
        "\"allocation_count_before\":%" PRId64 ","
        "\"allocation_count_after\":%" PRId64 ","
        "\"allocated_bytes_before\":%" PRId64 ","
        "\"allocated_bytes_after\":%" PRId64 ","
        "\"allocations_reason\":null,"
        "\"peak_rss_kb\":",
        iterations,
        warmup,
        elapsed,
        (double)elapsed / (double)iterations,
        checksum,
        memory_before.malloc_count,
        memory_after.malloc_count,
        memory_before.malloc_size,
        memory_after.malloc_size);
    if (peak_rss_kb >= 0) {
        printf("%" PRId64 ",\"peak_rss_reason\":null}\n", peak_rss_kb);
    } else {
        printf(
            "null,\"peak_rss_reason\":"
            "\"unable to read /proc/self/status VmHWM\"}\n");
    }
    return 0;
}
