#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>

#include "libregexp.h"

#define DEFAULT_COMPILE_ITERATIONS 100
#define DEFAULT_EXEC_ITERATIONS 1000
#define DEFAULT_WARMUP 20

typedef struct {
    char *name;
    uint8_t *pattern;
    size_t pattern_len;
    int flags;
    uint8_t *input;
    int input_len;
    int cbuf_type;
} Case;

typedef struct {
    Case *items;
    size_t len;
    size_t cap;
} CaseList;

int lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque;
    (void)alloca_size;
    return 0;
}

int lre_check_timeout(void *opaque)
{
    (void)opaque;
    return 0;
}

void *lre_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void free_case(Case *c)
{
    free(c->name);
    free(c->pattern);
    free(c->input);
    memset(c, 0, sizeof(*c));
}

static void free_case_list(CaseList *list)
{
    for (size_t i = 0; i < list->len; i++)
        free_case(&list->items[i]);
    free(list->items);
    memset(list, 0, sizeof(*list));
}

static char *dup_slice(const char *s)
{
    size_t len = strlen(s);
    char *out = malloc(len + 1);
    if (!out)
        return NULL;
    memcpy(out, s, len + 1);
    return out;
}

static int append_case(CaseList *list, Case c)
{
    if (list->len == list->cap) {
        size_t new_cap = list->cap ? list->cap * 2 : 64;
        Case *new_items = realloc(list->items, new_cap * sizeof(list->items[0]));
        if (!new_items)
            return -1;
        list->items = new_items;
        list->cap = new_cap;
    }
    list->items[list->len++] = c;
    return 0;
}

static int hex_value(int ch)
{
    if ('0' <= ch && ch <= '9')
        return ch - '0';
    if ('a' <= ch && ch <= 'f')
        return ch - 'a' + 10;
    if ('A' <= ch && ch <= 'F')
        return ch - 'A' + 10;
    return -1;
}

static uint8_t *decode_hex_bytes(const char *hex, size_t *out_len)
{
    size_t hex_len = strlen(hex);
    if ((hex_len & 1) != 0)
        return NULL;
    size_t len = hex_len / 2;
    uint8_t *out = malloc(len + 1);
    if (!out)
        return NULL;
    for (size_t i = 0; i < len; i++) {
        int hi = hex_value((unsigned char)hex[i * 2]);
        int lo = hex_value((unsigned char)hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            free(out);
            return NULL;
        }
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    out[len] = '\0';
    *out_len = len;
    return out;
}

static uint8_t *decode_hex_utf16le(const char *hex, int *out_units)
{
    size_t hex_len = strlen(hex);
    if ((hex_len % 4) != 0)
        return NULL;
    size_t units_len = hex_len / 4;
    if (units_len > INT_MAX)
        return NULL;
    uint16_t *out = malloc((units_len ? units_len : 1) * sizeof(out[0]));
    if (!out)
        return NULL;
    for (size_t i = 0; i < units_len; i++) {
        int lo_hi = hex_value((unsigned char)hex[i * 4]);
        int lo_lo = hex_value((unsigned char)hex[i * 4 + 1]);
        int hi_hi = hex_value((unsigned char)hex[i * 4 + 2]);
        int hi_lo = hex_value((unsigned char)hex[i * 4 + 3]);
        if (lo_hi < 0 || lo_lo < 0 || hi_hi < 0 || hi_lo < 0) {
            free(out);
            return NULL;
        }
        uint16_t lo_byte = (uint16_t)((lo_hi << 4) | lo_lo);
        uint16_t hi_byte = (uint16_t)((hi_hi << 4) | hi_lo);
        out[i] = (uint16_t)(lo_byte | (hi_byte << 8));
    }
    *out_units = (int)units_len;
    return (uint8_t *)out;
}

static int parse_flags(const char *flags_text, int *out_flags)
{
    int flags = 0;
    for (const unsigned char *p = (const unsigned char *)flags_text; *p; p++) {
        switch (*p) {
        case 'd':
            flags |= LRE_FLAG_INDICES;
            break;
        case 'g':
            flags |= LRE_FLAG_GLOBAL;
            break;
        case 'i':
            flags |= LRE_FLAG_IGNORECASE;
            break;
        case 'm':
            flags |= LRE_FLAG_MULTILINE;
            break;
        case 's':
            flags |= LRE_FLAG_DOTALL;
            break;
        case 'u':
            flags |= LRE_FLAG_UNICODE;
            break;
        case 'v':
            flags |= LRE_FLAG_UNICODE_SETS;
            break;
        case 'y':
            flags |= LRE_FLAG_STICKY;
            break;
        default:
            return -1;
        }
    }
    *out_flags = flags;
    return 0;
}

static int split_tabs(char *line, char **fields, int field_count)
{
    int count = 0;
    fields[count++] = line;
    for (char *p = line; *p; p++) {
        if (*p != '\t')
            continue;
        if (count >= field_count)
            return -1;
        *p = '\0';
        fields[count++] = p + 1;
    }
    return count == field_count ? 0 : -1;
}

static int parse_case_line(char *line, Case *out)
{
    char *fields[5];
    memset(out, 0, sizeof(*out));
    if (split_tabs(line, fields, 5) != 0)
        return -1;

    out->name = dup_slice(fields[0]);
    if (!out->name)
        return -1;

    if (parse_flags(fields[1], &out->flags) != 0)
        return -1;

    out->pattern = decode_hex_bytes(fields[2], &out->pattern_len);
    if (!out->pattern)
        return -1;

    if (strcmp(fields[3], "latin1") == 0) {
        size_t input_len = 0;
        out->input = decode_hex_bytes(fields[4], &input_len);
        if (!out->input || input_len > INT_MAX)
            return -1;
        out->input_len = (int)input_len;
        out->cbuf_type = 0;
    } else if (strcmp(fields[3], "utf16le") == 0) {
        out->input = decode_hex_utf16le(fields[4], &out->input_len);
        if (!out->input)
            return -1;
        out->cbuf_type = 1;
    } else {
        return -1;
    }

    return 0;
}

static int load_cases(const char *path, CaseList *out)
{
    memset(out, 0, sizeof(*out));
    FILE *file = fopen(path, "r");
    if (!file) {
        fprintf(stderr, "unable to open %s: %s\n", path, strerror(errno));
        return -1;
    }

    char *line = NULL;
    size_t line_cap = 0;
    unsigned line_no = 0;
    while (getline(&line, &line_cap, file) != -1) {
        line_no++;
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len == 0 || line[0] == '#')
            continue;

        Case c;
        if (parse_case_line(line, &c) != 0) {
            fprintf(stderr, "invalid regexp direct case at %s:%u\n", path, line_no);
            free_case(&c);
            free(line);
            fclose(file);
            free_case_list(out);
            return -1;
        }
        if (append_case(out, c) != 0) {
            fprintf(stderr, "out of memory\n");
            free_case(&c);
            free(line);
            fclose(file);
            free_case_list(out);
            return -1;
        }
    }

    free(line);
    fclose(file);
    return 0;
}

static int parse_nonnegative_int(const char *text, int fallback)
{
    if (!text)
        return fallback;
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0 || value > INT_MAX) {
        fprintf(stderr, "invalid iteration count: %s\n", text);
        exit(2);
    }
    return (int)value;
}

static void run_case(const Case *c, int compile_iterations, int exec_iterations, int warmup)
{
    int compile_warmup = warmup < compile_iterations ? warmup : compile_iterations;
    for (int i = 0; i < compile_warmup; i++) {
        int bytecode_len = 0;
        char error_msg[256];
        uint8_t *compiled = lre_compile(&bytecode_len, error_msg, sizeof(error_msg),
                                        (const char *)c->pattern, c->pattern_len,
                                        c->flags, NULL);
        if (!compiled) {
            fprintf(stderr, "compile failed for %s: %s\n", c->name, error_msg);
            exit(1);
        }
        lre_realloc(NULL, compiled, 0);
    }

    uint64_t compile_start = monotonic_ns();
    for (int i = 0; i < compile_iterations; i++) {
        int bytecode_len = 0;
        char error_msg[256];
        uint8_t *compiled = lre_compile(&bytecode_len, error_msg, sizeof(error_msg),
                                        (const char *)c->pattern, c->pattern_len,
                                        c->flags, NULL);
        if (!compiled) {
            fprintf(stderr, "compile failed for %s: %s\n", c->name, error_msg);
            exit(1);
        }
        lre_realloc(NULL, compiled, 0);
    }
    uint64_t compile_elapsed = monotonic_ns() - compile_start;
    printf("quickjs-libregexp,%s,compile,%d,%llu,0\n",
           c->name, compile_iterations, (unsigned long long)compile_elapsed);

    int bytecode_len = 0;
    char error_msg[256];
    uint8_t *bytecode = lre_compile(&bytecode_len, error_msg, sizeof(error_msg),
                                    (const char *)c->pattern, c->pattern_len,
                                    c->flags, NULL);
    if (!bytecode) {
        fprintf(stderr, "compile failed for %s: %s\n", c->name, error_msg);
        exit(1);
    }

    int capture_slots = lre_get_alloc_count(bytecode);
    uint8_t **captures = calloc((size_t)capture_slots, sizeof(captures[0]));
    if (!captures) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }

    for (int i = 0; i < warmup; i++) {
        int ret = lre_exec(captures, bytecode, c->input, 0, c->input_len, c->cbuf_type, NULL);
        if (ret < 0) {
            fprintf(stderr, "exec failed for %s: %d\n", c->name, ret);
            exit(1);
        }
    }

    int matches = 0;
    uint64_t start = monotonic_ns();
    for (int i = 0; i < exec_iterations; i++) {
        int ret = lre_exec(captures, bytecode, c->input, 0, c->input_len, c->cbuf_type, NULL);
        if (ret < 0) {
            fprintf(stderr, "exec failed for %s: %d\n", c->name, ret);
            exit(1);
        }
        if (ret == 1)
            matches++;
    }
    uint64_t elapsed = monotonic_ns() - start;

    printf("quickjs-libregexp,%s,exec,%d,%llu,%d\n",
           c->name, exec_iterations, (unsigned long long)elapsed, matches);

    free(captures);
    lre_realloc(NULL, bytecode, 0);
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 5) {
        fprintf(stderr, "usage: %s cases.tsv [compile_iterations] [exec_iterations] [warmup]\n", argv[0]);
        return 2;
    }

    const char *cases_path = argv[1];
    int compile_iterations = parse_nonnegative_int(argc > 2 ? argv[2] : NULL, DEFAULT_COMPILE_ITERATIONS);
    int exec_iterations = parse_nonnegative_int(argc > 3 ? argv[3] : NULL, DEFAULT_EXEC_ITERATIONS);
    int warmup = parse_nonnegative_int(argc > 4 ? argv[4] : NULL, DEFAULT_WARMUP);

    CaseList cases;
    if (load_cases(cases_path, &cases) != 0)
        return 1;

    printf("engine,case,phase,iterations,nanoseconds,matches\n");
    for (size_t i = 0; i < cases.len; i++)
        run_case(&cases.items[i], compile_iterations, exec_iterations, warmup);

    free_case_list(&cases);
    return 0;
}
