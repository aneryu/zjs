#ifndef ZJS_IRREGEXP_H_
#define ZJS_IRREGEXP_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum zjs_irregexp_status {
    ZJS_IRREGEXP_OK = 0,
    ZJS_IRREGEXP_NO_MATCH = 1,
    ZJS_IRREGEXP_SYNTAX = 2,
    ZJS_IRREGEXP_OOM = 3,
    ZJS_IRREGEXP_TIMEOUT = 4,
    ZJS_IRREGEXP_STACK = 5,
    ZJS_IRREGEXP_CORRUPT = 6,
};

enum zjs_irregexp_width {
    ZJS_IRREGEXP_LATIN1 = 0,
    ZJS_IRREGEXP_UTF16 = 1,
};

typedef int (*zjs_irregexp_interrupt_fn)(void* opaque);

typedef struct zjs_irregexp_compile_out {
    uint8_t* blob;
    size_t blob_len;
    const char* error_message;
} zjs_irregexp_compile_out;

int zjs_irregexp_compile(
    const uint8_t* pattern,
    size_t pattern_len,
    int pattern_is_utf16,
    uint32_t v8_flags,
    zjs_irregexp_compile_out* out);

void zjs_irregexp_free(uint8_t* blob);

uint16_t zjs_irregexp_blob_zjs_flags(const uint8_t* blob, size_t blob_len);
uint16_t zjs_irregexp_blob_capture_count(const uint8_t* blob, size_t blob_len);
uint16_t zjs_irregexp_blob_register_count(const uint8_t* blob, size_t blob_len);
int zjs_irregexp_blob_group_name(
    const uint8_t* blob,
    size_t blob_len,
    size_t one_based_index,
    const uint8_t** name_out,
    size_t* name_len_out);

int zjs_irregexp_exec(
    const uint8_t* blob,
    size_t blob_len,
    const void* subject,
    size_t subject_len,
    int subject_width,
    size_t start_index,
    int32_t* registers,
    size_t register_count,
    zjs_irregexp_interrupt_fn interrupt,
    void* interrupt_opaque);

#ifdef __cplusplus
}
#endif

#endif
