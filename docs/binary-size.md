# Shipped binary composition

Diagnostic snapshot of the production `zjs` CLI, not a merge gate
([verification-policy.md](verification-policy.md)). Cross-configuration
comparisons must name the optimize mode; this page is **ReleaseFast**
only. `ReleaseSmall` was not measured.

| | |
| --- | --- |
| Date | 2026-09-21 |
| Commit | `9e915ba0` |
| Host | Linux aarch64 (ELF, dynamically linked) |
| Artifact | `zig build zjs-size -Doptimize=ReleaseFast` |
| Zig | 0.16.0, LLVM backend, `layout=short`, nan-boxed `JSValue` |

`zjs-size` is the same engine as `zjs` under a second install name so a
later `ReleaseSmall` build does not overwrite the shipped CLI
([build/artifacts.zig](../build/artifacts.zig)).

## Headline

| | Bytes | |
| --- | ---: | --- |
| Unstripped (full DWARF) | 21,405,152 | 20.41 MiB; `.debug*` is 17,772,539 B (83%) |
| **Stripped (`strip -s`)** | **3,317,952** | **3.16 MiB** — the tarball shape |
| Machine code (`.text` + `.text.*`) | 2,725,664 | 2.60 MiB |
| Opcode-handler island (`.text.zjs.op_handlers`) | 150,368 | 146.8 KiB |

The 2026-08-21 owner ruling closed the binary-size *campaign* at 4.26 MiB
stripped (`47cf81ef`; [CHANGELOG](../CHANGELOG.md), [backlog.md](backlog.md)).
That figure was not re-measured after `71505d11`. This snapshot is 946,640 B
smaller (−22%) than 4,264,592 B. The two builds were not reproduced
side-by-side; treat the delta as a description, not a bisect.

`strip --strip-unneeded` and `strip -s` produced the same file size on this
binary. GNU `size(1)` `text` (3,173,023) includes `.rodata` and `.eh_frame`,
not just executable instructions.

## Stripped file

File-backed sections of the stripped image (NOBITS such as `.bss` / `.tbss`
do not occupy file bytes):

| Section | Bytes | Share of payload |
| --- | ---: | ---: |
| `.text` | 2,575,296 | 78.0% |
| `.rodata` | 234,696 | 7.1% |
| `.eh_frame` | 179,888 | 5.4% |
| `.text.zjs.op_handlers` | 150,368 | 4.6% |
| `.data.rel.ro` | 100,624 | 3.0% |
| `.data` | 27,584 | 0.8% |
| `.eh_frame_hdr` | 23,628 | 0.7% |
| dynamic / PLT / notes / interp | ~10,765 | 0.3% |
| Section payload | 3,302,849 | |
| ELF overhead | 15,103 | |
| File | 3,317,952 | |

Machine code is 82.6% of the stripped file (`.text` + handler island).
Unwind tables (`.eh_frame*`) are ~199 KiB.

The unstripped build keeps symbols and DWARF on purpose: `nm`, `addr2line`,
and `perf` need them, and no build step strips by default
([release-checklist.md](release-checklist.md)). Nightly tarballs strip
post-link so `.text` and the handler island stay byte-identical to the
measured binary (`-fstrip` moves `.text` by 40 B).

## How the functions were attributed

`nm -S --defined-only` on the unstripped ReleaseFast binary. Text symbols
(`T/t/W/w`, `size > 0`) sum to 2,739,404 B, 100.5% of the `.text*`
sections — slight overcount from aliases such as `main`. Inlined callees
are charged to the surviving outer symbol.

Zig names look like `exec.array_ops.arrayByCopyCall`. The first two path
components are the module and file. Prefix rules:

| Bucket | Names |
| --- | --- |
| VM dispatch / opcode | `exec.tailcall_dispatch*`, `exec.vm_*`, `exec.zjs_vm`, `exec.small_inline`, `exec.frame`, `exec.stack`, `exec.builtin_dispatch` |
| Calls / construct / closures | `exec.call`, `exec.call_runtime`, `exec.call_site`, `exec.construct`, `exec.inline_calls`, `exec.host_invocation`, `exec.native_legacy`, `exec.closure`, `exec.class_init_ops` |
| Property / object ops | `exec.property_*`, `exec.object_*`, `exec.slot_ops`, `exec.reflect_*` |
| Array / String / Iterator | `exec.array_*`, `exec.string_*`, `exec.iterator_*`, `exec.forof_ops` |
| Other JS builtins | remaining `exec.*` |
| Parser / Lexer | `parser.*`, `lexer.*`, `simple_token.*`, `token.*` |
| Compiler | `compiler.*` |
| Bytecode | `bytecode.*` |
| GC | `core.gc*`, `core.object_gc` |
| Core object / value / runtime | remaining `core.*` |
| Libs | `libs.*` (regexp, unicode, bigint, number_format) |
| Host / public API | `js_context.*`, `native.*`, `event_loop.*`, `platform_clock.*` |
| CLI | `zjs.*` (the `src/cli/zjs.zig` root), `cli_process.*`, `panic_policy.*` |
| Zig std | `Io.*`, `hash_map.*`, `array_list.*`, `start.*`, `heap.*`, … |
| compiler_rt / C glue | `compiler_rt.*`, `memcpy` / `__*` |

Most `.rodata` symbols are `__anon_*` and cannot be named from `nm`.
Exceptions below are size-matched or have a Zig name.

## Machine code by architecture layer

Layers match [architecture.md](architecture.md). Percents are of attributed
text (2,739,404 B).

| Layer | Bytes | Share |
| --- | ---: | ---: |
| **exec (VM + calls + builtins)** | **1,534,836** | **56.0%** |
| parser + lexer | 333,948 | 12.2% |
| core (including GC) | 327,424 | 12.0% |
| Zig std + compiler_rt | 194,048 | 7.1% |
| libs | 139,544 | 5.1% |
| compiler | 119,380 | 4.4% |
| CLI + host API | 79,324 | 2.9% |
| bytecode | 10,744 | 0.4% |

Compile frontend (parser + lexer + compiler + bytecode) is **16.9%**.
GC itself is **79,360 B (2.9%)**; the rest of `core` is the object model,
runtime, strings, and typed arrays. The handler island is 5.5% of machine
code — the hot entry, not the bulk of opcode work.

[engine-evolution-plan.md](engine-evolution-plan.md) §2.2 recorded the
handler island at 163 KiB of a 3.74 MiB `.text`. This snapshot is 146.8 KiB
of 2.60 MiB `.text*`.

## Machine code by function

| Bucket | Bytes | Share | Symbols |
| --- | ---: | ---: | ---: |
| Other JS builtins | 431,872 | 15.8% | 422 |
| Array / String / Iterator | 360,628 | 13.2% | 280 |
| Parser / Lexer | 333,948 | 12.2% | 277 |
| VM dispatch / opcode | 329,176 | 12.0% | 523 |
| Calls / construct / closures | 292,032 | 10.7% | 266 |
| Core object / value / runtime | 248,064 | 9.1% | 440 |
| Zig std | 186,640 | 6.8% | 314 |
| Libs (regexp / unicode / bigint) | 139,544 | 5.1% | 101 |
| Property / object ops | 121,128 | 4.4% | 117 |
| Compiler | 119,380 | 4.4% | 78 |
| GC | 79,360 | 2.9% | 87 |
| CLI | 69,228 | 2.5% | 13 |
| Bytecode | 10,744 | 0.4% | 28 |
| Host / public API | 10,096 | 0.4% | 20 |
| compiler_rt / C glue | 7,408 | 0.3% | 10 |
| Unclassified (`opcode_logical.traitsOf`) | 156 | 0.0% | 1 |

Volume is not “one large VM”. It is **exec builtins and the call path**,
then the **parser**. Handler code plus `exec.array_ops` / `call_runtime` /
`string_ops` / `object_ops` is the specialized-opcode position already
described in [backlog.md](backlog.md) (a lean monolithic dispatch was
built and rejected).

### `exec.*` files (machine code)

| File | Bytes | Share of exec |
| --- | ---: | ---: |
| `tailcall_dispatch` | 183,716 | 12.0% |
| `array_ops` | 163,072 | 10.6% |
| `call_runtime` | 97,216 | 6.3% |
| `string_ops` | 91,916 | 6.0% |
| `object_ops` | 90,060 | 5.9% |
| `native_legacy` | 67,568 | 4.4% |
| `inline_calls` | 62,712 | 4.1% |
| `iterator_ops` | 62,592 | 4.1% |
| `promise_ops` | 42,936 | 2.8% |
| `standard_globals` | 42,272 | 2.8% |
| `string_builtin_ops` | 39,656 | 2.6% |
| `json_ops` | 38,988 | 2.5% |
| `module_graph` | 34,676 | 2.3% |
| `collection_ops` | 32,964 | 2.1% |
| `value_ops` | 32,888 | 2.1% |
| remaining `exec.*` | 511,604 | 33.3% |
| **exec total** | **1,534,836** | |

“Other JS builtins” (431,872 B) inside that remainder, largest first:

| File | Bytes |
| --- | ---: |
| `promise_ops` | 42,936 |
| `standard_globals` | 42,272 |
| `json_ops` | 38,988 |
| `module_graph` | 34,676 |
| `collection_ops` | 32,964 |
| `value_ops` | 32,888 |
| `date_ops` | 23,304 |
| `module` | 22,968 |
| `print_inspector` | 21,624 |
| `atomics_ops` | 18,056 |
| `math_ops` | 17,868 |
| `uri_ops` | 17,640 |
| `regexp_fastpath` | 14,324 |

`print_inspector` (object printer) is linked into the production CLI.

The handler island contains 299 symbols, 145,996 B (97.1% of the section),
all `exec.tailcall_dispatch`.

### `core.*`, parser, compiler, libs

`core` machine code 327,424 B:

| File | Bytes | Share of core |
| --- | ---: | ---: |
| `object` | 96,280 | 29.4% |
| `gc_trace_stw` | 45,320 | 13.8% |
| `runtime` | 32,936 | 10.1% |
| `memory` | 18,332 | 5.6% |
| `string` | 14,684 | 4.5% |
| `typed_array` | 13,376 | 4.1% |
| `gc_block_heap` | 12,768 | 3.9% |
| `gc` | 10,276 | 3.1% |
| remaining `core.*` | 83,452 | 25.5% |

GC files together (`gc*`, 79,360 B): `gc_trace_stw` 45,320 ·
`gc_block_heap` 12,768 · `gc` 10,276 · `gc_address_registry` 6,112 ·
`gc_registry_pins` 3,100 · `gc_mark_queue` 1,084 · `gc_generation` 356 ·
`gc_registry_diagnostics` 344.

Parser 299,588 B: `statements` 61,224 · `expressions` 43,172 ·
`typescript` 42,640 · `functions` 40,124 · `classes` 27,616 ·
`parse_state` 18,264 · `emitter` 16,872 · `compile_entry` 13,480 ·
`modules` 11,428 · `lookahead` 11,220. Lexer is 26,444 B, almost all
`Lexer.nextInto` and friends.

Compiler 119,380 B: `resolve_labels` 43,072 · `resolve_variables` 35,072 ·
`finalize` 25,040 · `binding_rules` 8,996.

Libs 139,544 B: `regexp` 81,104 (58%) · `unicode` 26,320 · `bigint` 16,196 ·
`number_format` 15,924.

### Largest text symbols

| Bytes | Symbol |
| ---: | --- |
| 23,616 | `libs.regexp.execCaptureSlotsParsed` |
| 20,696 | `parser.classes.parseClass` |
| 20,584 | `zjs.dumpRequested` |
| 19,624 | `zjs.main` |
| 17,856 | `compiler.resolve_variables.Resolver.run` |
| 16,028 | `exec.string_ops.regExpSymbolReplace` |
| 15,464 | `exec.string_builtin_ops.methodCall` |
| 14,672 | `compiler.finalize.createFunctionBytecodeAfterChildren` |
| 14,172 | `exec.array_ops.stableArraySortEntries` |
| 13,624 | `zjs.evalSource` |
| 11,160 | `core.gc_trace_stw.collectMinor` |
| 8,820 | `exec.vm_native.dispatch` |

`zjs.dumpRequested` (CLI dump) is always linked in ReleaseFast. CLI text
is 69,228 B total: `dumpRequested` 20,584 · `main` 19,624 · `evalSource`
13,624 · fingerprint / exception / GC-dump helpers the rest.

Zig std text is 186,640 B, of which **`Io.Threaded` is 92,464 B** (the
host event loop pulls `std.Io`). Next are `Io.Writer` 9,080 ·
`hash_map.HashMapUnmanaged` 8,316 · `start.main` 5,760. `compiler_rt`
in the std bucket is small (`rem_pio2*` ~5 KB).

## Read-only and relro data

`.rodata` is 234,696 B. `nm` names 212,627 B (90.6%); most of that is
`__anon_*`. Identified pieces:

| Bytes | What |
| ---: | --- |
| 45,520 | `__anon_*` matching `src/libs/unicode_tables.bin` (45,519 B on disk) |
| 26,944 | `bytecode.opcode.decode.layout_table` |

`.data.rel.ro` (100,624 B) includes dispatch and realm tables:
`bytecode.opcode.opcode_info` 6,624 · `exec.vm_property_field.no_prop_sites`
8,192 · `exec.standard_globals.{string,date,array}_prototype` and
`math_methods`. BSS does not affect file size; the largest reservation is
`Thread.maybeAttachSignalStack.global.signal_stack` at 262,144 B virtual.

## How to remeasure

```sh
zig build zjs-size -Doptimize=ReleaseFast --summary all
# keep the unstripped binary for nm; copy before stripping
cp zig-out/bin/zjs-size /tmp/zjs-size
strip -s -o /tmp/zjs-size.stripped /tmp/zjs-size
ls -l /tmp/zjs-size /tmp/zjs-size.stripped
size /tmp/zjs-size
readelf -W -S /tmp/zjs-size
nm -S --defined-only /tmp/zjs-size | awk '$3 ~ /^[TtWw]$/'
```

Use `zjs-size`, not `zjs`, so a Debug CLI already in `zig-out/bin/zjs` is
not overwritten. Declare `-Doptimize` in any comparison.
A default `zig build` is Debug and is not this snapshot: Debug is ~21 MiB
on disk for the same reason (DWARF), with a similar `.text` but a
different layout.
