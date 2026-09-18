# 15 — String / RegExp-string 运行时（`string_ops.zig`）

本文件是 `src/exec/string_ops.zig` 的类型地图与子文档目录。逐函数见 `15-string-ops-*.md` 与 `15-string-builtin.md`。

## 文件职责

- `string_ops.zig`：ToString、concat、replace/match/split、RegExp 符号方法、以及历史放在这里的 `arraySearchCall` / `arrayConcatCall` / `Object.prototype.toString`。
- `string_builtin_ops.zig`：`.string` record 表、`prim_self` 叶子（charAt/charCodeAt/at/codePointAt）、latin1 concat 快路径、过渡 `methodCall`。
- String.prototype 方法的 this 强制：普通方法用 `toStringCheckObject`（nullish → 「null or undefined are forbidden」）；RegExp 耦合方法用「cannot convert to object」。

## 类型

- `QjsConcatPart`：直接 concat 路径上的 `{value, latin1切片}`。
- `ErrorStackStringKind`：live vs captured 错误栈。
- `ReplaceMatch`：一次 replace 命中的 `{result, matched, index, captures, groups}`。
- `ReplaceMatchRoots`：把堆上 `ArrayList(ReplaceMatch)` 注册成 RootProvider；否则 replacer 回调触发 GC 时 named groups 会被回收（test262 `functional-replace-global.js` + `ZJS_GC_STRESS`）。
- `SlotCaptureRef`：`regExpReplaceFast` 解析替换模板 `$n` / `$nn` 的结果 `{group, consumed}`（`$<name>` 不在快路径，带命名分组时整条快路径回退）。
- `RegExpMatch`：matcher 捕获槽的借用视图；`captureAt` / `captureNameAt` 读 group。
- `LazyRegExpLegacyCapture`：把 start/len 打进 immediate payload，避免立刻切片字符串。
- `StringBuffer`：latin1→utf16 可拓宽的拼接缓冲（pad 等）。
- `NormalizedUtf32`：localeCompare/normalize 的 NFC/NFD/NFKC/NFKD 码点缓冲。

## 子文档

| 文件 | 覆盖 |
| --- | --- |
| [15-string-ops-core.md](15-string-ops-core.md) | ToString、concat、RegExp 符号方法、replace |
| [15-string-ops-rest.md](15-string-ops-rest.md) | prototype 分发、array concat/search、toString、pad/html |
| [15-string-builtin.md](15-string-builtin.md) | record 表与直接叶子 |

## 覆盖核对

- 清单函数数: 0（本文件只含类型与目录）
- 本文标题覆盖: 0
- 未覆盖: 无
