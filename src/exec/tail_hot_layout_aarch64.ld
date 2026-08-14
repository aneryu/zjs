/*
 * L-1 structural cluster: every dispatch Handler lives in
 * `.text.zjs.op_handlers`. Source order (object-file emission) is the
 * order. Pull the section out of `.text` as one page-aligned island so
 * get_arg0..3 are no longer pinned a megabyte away from the loc/arith
 * bodies (R6-F: that pin alone made the zlib 27-op set span 269 pages).
 *
 * INSERT BEFORE .text keeps the island adjacent to the rest of the
 * engine text without imposing AArch64 assumptions on other targets
 * (build.zig only attaches this script on aarch64 ELF).
 */
SECTIONS
{
  .text.zjs.op_handlers ALIGN(CONSTANT(MAXPAGESIZE)) :
  {
    KEEP(*(.text.zjs.op_handlers))
    KEEP(*(.text.zjs.op_handlers.*))
  }

  ASSERT(SIZEOF(.text.zjs.op_handlers) > 0,
         "L-1 op-handler cluster is empty")
}

INSERT BEFORE .text;
