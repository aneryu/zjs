/*
 * AArch64 source-local dispatch island for get_arg0..3.
 *
 * Each handler is 56 bytes. The offsets below keep every body inside one
 * 64-byte I-cache line while placing its terminal indirect branch at a
 * different line offset. Assertions turn compiler or linker layout drift into
 * a build failure instead of silently invalidating the measured placement.
 */
SECTIONS
{
  .text.zjs.tail_hot ALIGN(CONSTANT(MAXPAGESIZE)) : ALIGN(64)
  {
    __zjs_get_arg_island_start = .;

    . += 0x208;
    __zjs_get_arg0_start = .;
    KEEP(*(.text.zjs.tail_hot.0110))
    __zjs_get_arg0_end = .;

    . = ALIGN(0x80);
    __zjs_get_arg1_start = .;
    KEEP(*(.text.zjs.tail_hot.0120))
    __zjs_get_arg1_end = .;

    . = ALIGN(0x100);
    . += 4;
    __zjs_get_arg2_start = .;
    KEEP(*(.text.zjs.tail_hot.0130))
    __zjs_get_arg2_end = .;

    . = ALIGN(0x80);
    . += 8;
    __zjs_get_arg3_start = .;
    KEEP(*(.text.zjs.tail_hot.0140))
    __zjs_get_arg3_end = .;

    . = ALIGN(CONSTANT(MAXPAGESIZE));
  }

  ASSERT(__zjs_get_arg0_start - __zjs_get_arg_island_start == 0x208,
         "get_arg0 handler placement drifted")
  ASSERT(__zjs_get_arg1_start - __zjs_get_arg_island_start == 0x280,
         "get_arg1 handler placement drifted")
  ASSERT(__zjs_get_arg2_start - __zjs_get_arg_island_start == 0x304,
         "get_arg2 handler placement drifted")
  ASSERT(__zjs_get_arg3_start - __zjs_get_arg_island_start == 0x388,
         "get_arg3 handler placement drifted")
  ASSERT(__zjs_get_arg0_end - __zjs_get_arg0_start == 0x38,
         "get_arg0 handler size drifted")
  ASSERT(__zjs_get_arg1_end - __zjs_get_arg1_start == 0x38,
         "get_arg1 handler size drifted")
  ASSERT(__zjs_get_arg2_end - __zjs_get_arg2_start == 0x38,
         "get_arg2 handler size drifted")
  ASSERT(__zjs_get_arg3_end - __zjs_get_arg3_start == 0x38,
         "get_arg3 handler size drifted")
  ASSERT(SIZEOF(.text.zjs.tail_hot) == CONSTANT(MAXPAGESIZE),
         "get_arg dispatch island must occupy exactly one maximum page")
}

INSERT BEFORE .text;
