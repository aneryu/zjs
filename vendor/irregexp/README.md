# Irregexp (V8) for zjs

Standalone interpreter + bytecode compiler extracted from V8 so zjs can
compile and execute ECMAScript regular expressions without linking V8 or
SpiderMonkey.

## Provenance

- Upstream: V8 `src/regexp/` Irregexp sources
- Pinned commit: see `IRREGEXP_VERSION`
- License: `LICENSE.v8` (BSD-3-Clause)

Imported sources live in `imported/`. Non-regexp `#include "src/..."` lines
were stripped and `#include "irregexp/RegExpShim.h"` was added. Printer
sources are present but must not be compiled into zjs.

## Build

Compile with:

- `-DCOMPILING_IRREGEXP_FOR_EXTERNAL_EMBEDDER`
- no `V8_INTL_SUPPORT`
- no `V8_ENABLE_REGEXP_DIAGNOSTICS`
- `-fno-exceptions`
- include path `vendor/` so `#include "irregexp/RegExpShim.h"` resolves

C ABI: `zjs_irregexp.h` / `zjs_irregexp.cpp`. Zig links this as static
library `zjs_irregexp` (`build/irregexp.zig`) and wraps it in
`src/libs/irregexp.zig`. The JS object layer still stores the blob as a
latin1 string.

Unicode case-fold and identifier predicates are `extern "C"` hooks
implemented in Zig; the shim provides weak ASCII fallbacks for bring-up.

## Blob format (little-endian)

```
magic u32 = 0x58525249 ('IRRX')
version u16 = 1
zjs_flags u16
capture_count u16          // including group 0
register_count u16
name_count u16
pad u16
latin1_off u32
latin1_len u32
uc16_off u32
uc16_len u32
// names: (index u16, len u16, utf8 bytes)*
// latin1 bytecode
// uc16 bytecode
```
