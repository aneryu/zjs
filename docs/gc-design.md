# Zig JS Runtime GC 设计方案

面向场景：**Zig 编写的 JavaScript 引擎 / JavaScript runtime，定位类似 Bun，网络层适配 uWS，用于 HTTP/WebSocket server。**

推荐结论：

```text
copying nursery
+ non-moving old space
+ mostly-concurrent / incremental old GC
+ precise handle/root system
+ card-table remembered set
+ external memory accounting
+ uWS event-loop aware GC scheduler
+ deferred finalizer / native cleanup queue
```

也就是：**年轻代可以移动，老年代默认不移动。**

这个取舍接近 JavaScriptCore 的工程方向。Bun 本身是 Zig runtime，并且底层使用 JavaScriptCore；JSC 的 GC 被 WebKit 描述为 non-compacting、generational、mostly-concurrent。这个事实对 Bun-like runtime 有参考价值：runtime/native 绑定复杂度很高时，老年代非移动可以显著降低嵌入风险。

---

## 目录

- [1. 目标](#1-目标)
- [2. 工作负载模型](#2-工作负载模型)
- [3. 总体架构](#3-总体架构)
- [4. 堆布局](#4-堆布局)
- [5. 对象表示](#5-对象表示)
- [6. Root 系统](#6-root-系统)
- [7. Write Barrier 与 Remembered Set](#7-write-barrier-与-remembered-set)
- [8. Minor GC](#8-minor-gc)
- [9. Major GC](#9-major-gc)
- [10. Selective Evacuation / Optional Compaction](#10-selective-evacuation--optional-compaction)
- [11. WeakRef、WeakMap、FinalizationRegistry](#11-weakrefweakmapfinalizationregistry)
- [12. Native Resource 生命周期](#12-native-resource-生命周期)
- [13. uWS 集成方案](#13-uws-集成方案)
- [14. GC Scheduler](#14-gc-scheduler)
- [15. 内存控制策略](#15-内存控制策略)
- [16. Safepoint 设计](#16-safepoint-设计)
- [17. JIT / Interpreter Root 支持](#17-jit--interpreter-root-支持)
- [18. String / Atom / Shape 策略](#18-string--atom--shape-策略)
- [19. ArrayBuffer / TypedArray](#19-arraybuffer--typedarray)
- [20. Error Handling 与 OOM 策略](#20-error-handling-与-oom-策略)
- [21. 并发设计](#21-并发设计)
- [22. API 设计](#22-api-设计)
- [23. 调参模式](#23-调参模式)
- [24. 监控指标](#24-监控指标)
- [25. 测试方案](#25-测试方案)
- [26. 分阶段实现路线](#26-分阶段实现路线)
- [27. 推荐默认配置](#27-推荐默认配置)
- [28. 关键工程规则](#28-关键工程规则)
- [29. 最终架构摘要](#29-最终架构摘要)
- [30. 参考资料](#30-参考资料)

---

## 1. 目标

### 1.1 设计目标

本 GC 的目标不是做一个学术上“最先进”的全堆压缩 GC，而是为 server runtime 取得稳定的工程最优点：

```text
高吞吐:
  每请求大量短命对象快速分配、快速回收。

低 p99 / p999 延迟:
  major GC 不应长时间阻塞 uWS event loop。

可控 RSS:
  JS heap、native buffer、ArrayBuffer、WebSocket backpressure buffer 都要进入内存压力模型。

native 嵌入安全:
  Zig/uWS 层不能因为 JS object moving 而出现悬垂指针。

长期运行稳定:
  server 连续运行数天或数周时，RSS 不应因为碎片、strong root 泄漏、external memory 漏记而持续增长。
```

### 1.2 非目标

第一版不追求：

```text
全堆 moving / compacting GC
跨 worker 共享 JS heap
依赖保守栈扫描作为长期方案
用引用计数管理 JS heap
finalizer 里直接执行用户 JS
finalizer 里直接操作 uWS socket
```

V8 的 Orinoco 是成熟的 parallel/concurrent GC，并包含 major mark-sweep-compact 等能力；但这类 moving/compacting 系统要求完整 handle discipline、pointer update、JIT stack map、safepoint、barrier、pinning 策略，复杂度不适合作为 Zig 自研 runtime 的第一目标。

---

## 2. 工作负载模型

uWS/Bun-like server 的对象生命周期通常是这样的：

```text
大量短命对象:
  Request wrapper
  Response wrapper
  Headers
  URL / URLSearchParams
  Promise reaction
  closure
  临时字符串
  JSON parse / stringify 中间对象
  small Array / Object literal

中等寿命对象:
  async task
  Promise chain
  ReadableStream / WritableStream
  WebSocket wrapper
  timer
  abort controller
  per-request context

长寿命对象:
  global object
  module registry
  route table
  handler function
  hidden class / shape / structure
  interned string
  server config
  WebSocket behavior callbacks

off-heap / native memory:
  socket
  TLS state
  compression context
  ArrayBuffer backing store
  HTTP body buffer
  stream queue
  file send buffer
  uWS backpressure buffer
```

因此 GC 优化重点是：

```text
短命 JS 对象:
  用年轻代 copying nursery 解决。

长寿命 JS 对象:
  放入非移动 old space，减少 native 绑定复杂度。

native/off-heap memory:
  不靠 JS wrapper 大小估算，必须显式记账。

server 延迟:
  major GC 必须 incremental/concurrent，并和 uWS event loop 协作。
```

uWS 的并发模型适合每个 worker/event-loop 一个 VM/heap：每个 worker thread 拥有独立 event loop、VM 和 JS heap，避免跨线程共享对象图。

---

## 3. 总体架构

```text
Process
└── Worker Thread N
    ├── uWS Event Loop
    ├── VM
    │   ├── JS Heap
    │   │   ├── Nursery / Young Generation
    │   │   ├── Old Space
    │   │   ├── Large Object Space
    │   │   └── Weak / Finalization Queues
    │   ├── Root Registry
    │   │   ├── VM frames
    │   │   ├── Handle scopes
    │   │   ├── Persistent handles
    │   │   ├── Async task roots
    │   │   ├── Timer roots
    │   │   └── Native resource roots
    │   ├── Remembered Set / Card Table
    │   ├── External Memory Counter
    │   └── GC Scheduler
    └── Optional GC Worker
```

核心原则：

```text
1. 每个 uWS worker thread 一个 VM / heap。
2. 默认禁止跨 heap JS object reference。
3. worker 之间通过 structured clone、message passing 或 transferable ArrayBuffer 传递数据。
4. old-space object 地址稳定。
5. young object 允许移动，但跨 GC 生命周期必须通过 handle。
6. 所有 external/native memory 都要向 GC 记账。
```

---

## 4. 堆布局

### 4.1 Nursery / Young Generation

年轻代负责绝大部分 per-request 临时对象。

推荐结构：

```text
Nursery
├── eden
│   └── bump allocation
├── to-space / survivor area
│   └── minor GC 时复制 live young object
└── promotion buffer
    └── survivor 晋升 old space
```

策略：

```text
新对象默认进入 eden。
eden 用 bump pointer 分配。
eden 满时触发 minor GC。
minor GC 只扫描 root set + remembered set。
存活年轻对象复制到 survivor 或晋升 old。
死亡对象不需要 sweep。
```

优点：

```text
分配极快。
短命对象回收成本低。
年轻代碎片低。
非常适合 HTTP request 临时对象。
```

缺点：

```text
young object 地址会变化。
Zig/native 层不能长期保存 young object 裸指针。
需要 forwarding pointer 或 forwarding table。
需要完整 handle discipline。
```

MVP 阶段如果 handle 系统尚未完全正确，可以先让 nursery 非移动；但生产目标应转向 copying nursery。

### 4.2 Old Space

老年代存放长寿命对象，默认非移动。

推荐结构：

```text
Old Space
├── size-class pages
│   ├── 16B cells
│   ├── 24B cells
│   ├── 32B cells
│   ├── 48B cells
│   ├── 64B cells
│   ├── 96B cells
│   ├── 128B cells
│   ├── 192B cells
│   ├── 256B cells
│   ├── 384B cells
│   ├── 512B cells
│   ├── 768B cells
│   └── 1024B+ cells
├── free lists
├── mark bitmap
├── page metadata
└── decommit queue
```

old space 规则：

```text
old object 地址稳定。
old object 用 mark-sweep 回收。
每个 page 只放一种 size class。
sweep 后空 page 可以 madvise / decommit。
碎片严重时可以做 selective evacuation，但不是第一版要求。
```

非移动 old space 的关键不是“永远不整理”，而是用 allocator 控制碎片：

```text
按 size class 分页。
空页归还 OS。
低 live ratio page 进入 evacuation candidate list。
长时间未使用 page 进入 cold page list。
```

### 4.3 Large Object Space

大对象不进入普通 size-class page。

适合进入 large object space 的对象：

```text
大 Array
大 string
大 TypedArray wrapper metadata
大 Map / Set backing table
大 regexp cache
大 object property storage
```

策略：

```text
large object 单独 mmap 或 slab 分配。
large object 默认非移动。
mark 后不可达则释放。
live large object 可以按需 madvise unused tail。
```

注意：`ArrayBuffer` 的 backing store 不建议直接作为普通 JS heap object 管理。JS wrapper 是 GC cell；真实 backing store 应走 external/native memory 记账。

### 4.4 External Memory

external memory 是 server runtime 的核心问题。

必须记账的内容：

```text
ArrayBuffer backing store
Blob data
HTTP request body buffer
HTTP response body buffer
ReadableStream queue
WritableStream queue
WebSocket send queue
uWS backpressure buffer
TLS session/context
compression context
file buffer
native addon allocation
FFI allocation
```

接口示意：

```zig
pub const ExternalMemoryToken = struct {
    vm: *VM,
    bytes: usize,

    pub fn release(self: *ExternalMemoryToken) void {
        self.vm.gc.reportExternalFree(self.bytes);
        self.bytes = 0;
    }
};

pub fn reportExternalAlloc(gc: *GC, bytes: usize) ExternalMemoryToken {
    gc.external_bytes += bytes;
    gc.allocation_debt += bytes * gc.policy.external_weight;
    gc.scheduler.maybeRequestGC(.external_memory);
    return .{ .vm = gc.vm, .bytes = bytes };
}

pub fn reportExternalFree(gc: *GC, bytes: usize) void {
    gc.external_bytes -= bytes;
}
```

---

## 5. 对象表示

### 5.1 JSValue

推荐使用 tagged value 或 NaN-boxing。示意：

```zig
pub const JSValue = packed struct {
    raw: u64,

    pub inline fn isCell(self: JSValue) bool {
        return (self.raw & TAG_MASK) == TAG_CELL;
    }

    pub inline fn asCell(self: JSValue) *Cell {
        return @ptrFromInt(self.raw & PTR_MASK);
    }
};
```

建议类型：

```text
undefined
null
boolean
int32
double
cell pointer
symbol
small string / atom reference
```

### 5.2 Cell Header

示意：

```zig
pub const Generation = enum(u2) {
    young,
    old,
    large,
    immortal,
};

pub const CellState = enum(u2) {
    white,
    grey,
    black,
    forwarded,
};

pub const CellHeader = packed struct {
    type_id: u16,
    size_class: u8,
    generation: Generation,
    state: CellState,
    mark_epoch: u2,

    remembered: bool,
    has_finalizer: bool,
    has_weak_edges: bool,
    has_external_memory: bool,
    pinned: bool,

    flags: u16,
};
```

说明：

```text
type_id:
  找到 trace/finalize/size descriptor。

generation:
  区分 young/old/large/immortal。

state:
  用于 marking 或 forwarding。

mark_epoch:
  避免每次 full GC 清空所有 mark bits。

remembered:
  old object 是否已经进入 remembered set。

pinned:
  native 临时 pin，minor GC 时直接晋升或特殊处理。
```

### 5.3 TypeInfo / Trace Descriptor

每个 GC-managed 类型必须提供 trace 函数。

```zig
pub const TypeInfo = struct {
    name: []const u8,

    trace: *const fn (tracer: *Tracer, cell: *Cell) void,
    finalize: ?*const fn (rt: *Runtime, cell: *Cell) void,

    size: *const fn (cell: *Cell) usize,

    has_weak_edges: bool,
    has_external_memory: bool,
};
```

示例：

```zig
fn traceJSObject(tracer: *Tracer, cell: *Cell) void {
    const obj: *JSObject = @fieldParentPtr("cell", cell);

    tracer.edge(&obj.shape);
    tracer.edge(&obj.prototype);

    for (obj.inline_slots) |*slot| {
        tracer.edgeValue(slot);
    }

    if (obj.out_of_line_slots) |slots| {
        for (slots.values) |*slot| {
            tracer.edgeValue(slot);
        }
    }
}
```

原则：

```text
trace 只枚举 JS heap edge。
trace 不释放 native resource。
trace 不执行用户 JS。
trace 不做阻塞 I/O。
```

---

## 6. Root 系统

### 6.1 Root 类型

GC root 包括：

```text
VM global roots:
  global object
  intrinsic objects
  builtins
  module registry
  atom table / interned strings
  hidden class roots

Execution roots:
  interpreter operand stack
  call frames
  bytecode registers
  exception object
  current lexical environment

Handle roots:
  HandleScope locals
  Persistent handles
  WeakPersistent handles

Async roots:
  Promise jobs
  microtask queue
  timer callbacks
  async I/O continuation
  stream callbacks
  WebSocket callbacks
  AbortSignal listeners

Native roots:
  uWS server behavior callbacks
  active request/response bridge
  active WebSocket session data
  native addon persistent references
```

### 6.2 Handle Discipline

Zig 层不能长期保存裸 `*Cell` / `*JSObject`。

规则：

```text
Local handle:
  只在当前 HandleScope 内有效。

Persistent handle:
  可以跨 event-loop tick、await、callback、timer 存活。
  必须显式 release。

WeakPersistent handle:
  不阻止 GC。
  对象死亡后进入 weak/finalizer 流程。

裸指针:
  只允许在不会 allocation、不会调用用户 JS、不会进入 event loop、不会触发 GC 的短路径里使用。
```

API 示意：

```zig
pub const HandleScope = struct {
    vm: *VM,
    start: usize,

    pub fn enter(vm: *VM) HandleScope {
        return .{ .vm = vm, .start = vm.handles.len };
    }

    pub fn exit(self: *HandleScope) void {
        self.vm.handles.shrinkRetainingCapacity(self.start);
    }

    pub fn local(self: *HandleScope, value: JSValue) Local {
        const slot = self.vm.handles.appendSlot(value);
        return .{ .slot = slot };
    }
};

pub const Local = struct {
    slot: *JSValue,

    pub inline fn get(self: Local) JSValue {
        return self.slot.*;
    }
};

pub const Persistent = struct {
    vm: *VM,
    slot: *RootSlot,

    pub fn deinit(self: *Persistent) void {
        self.vm.roots.freePersistent(self.slot);
    }
};
```

---

## 7. Write Barrier 与 Remembered Set

### 7.1 为什么需要 barrier

分代 GC 只扫描 young generation 时，必须知道 old object 是否指向 young object。否则 young object 可能被错误回收。

同时，incremental/concurrent marking 期间，mutator 还在修改对象图，barrier 必须维持 marking 正确性。

### 7.2 Barrier 设计

使用组合 barrier：

```text
old-to-young barrier:
  记录 old object / card 指向 young object。

incremental marking barrier:
  marking 阶段，如果 black object 写入 white child，则 shade child。
```

示意：

```zig
pub inline fn writeValue(
    vm: *VM,
    owner: *Cell,
    slot: *JSValue,
    value: JSValue,
) void {
    slot.* = value;

    if (!value.isCell()) return;

    const child = value.asCell();

    vm.gc.writeBarrier(owner, slot, child);
}

pub inline fn writeBarrier(
    gc: *GC,
    owner: *Cell,
    slot: *JSValue,
    child: *Cell,
) void {
    // Generational barrier
    if (owner.header.generation == .old and child.header.generation == .young) {
        gc.card_table.mark(slot);
        if (!owner.header.remembered) {
            owner.header.remembered = true;
            gc.remembered_set.push(owner);
        }
    }

    // Incremental marking barrier
    if (gc.phase == .marking and owner.header.state == .black and child.header.state == .white) {
        gc.shade(child);
    }
}
```

必须走 barrier 的写入位置：

```text
object property write
array element write
closure environment write
prototype write
shape transition write
Map / Set entry write
Promise reaction write
WeakMap key/value write
module namespace write
global variable write
native wrapper JS field write
```

批量写入要用 bulk barrier：

```zig
pub fn writeArrayRange(
    vm: *VM,
    owner: *JSArray,
    start: usize,
    values: []const JSValue,
) void {
    @memcpy(owner.elements[start..][0..values.len], values);

    if (vm.gc.needsBarrier(owner.cell())) {
        vm.gc.bulkWriteBarrier(owner.cell(), owner.elements[start..][0..values.len]);
    }
}
```

---

## 8. Minor GC

### 8.1 触发条件

```text
eden allocation pointer 超过 limit
nursery allocation debt 超阈值
young external wrapper 数量过多
显式 stress GC
```

### 8.2 Minor GC 输入

```text
roots:
  VM frames
  handle scopes
  persistent roots
  async roots
  native roots

remembered set:
  old object / cards that may point to young

young objects:
  eden + survivor
```

### 8.3 Minor GC 算法

```text
1. stop-the-world 当前 VM mutator。
2. 初始化 worklist。
3. 扫描 roots，发现 young object:
   - copy 到 to-space，或
   - 满足晋升条件则 promote 到 old。
4. 扫描 remembered set/cards:
   - old -> young edge 更新为 forwarded address。
5. trace copied/promoted young objects。
6. 处理 pinned young object:
   - 优先 promote 到 old。
7. 清空 from-space。
8. 交换 nursery spaces。
9. 更新 survival rate、promotion rate、pause time。
```

伪代码：

```zig
pub fn minorGC(vm: *VM) void {
    const gc = &vm.gc;

    gc.phase = .minor;
    gc.stats.minor_count += 1;

    var tracer = YoungTracer.init(gc);

    gc.scanRoots(&tracer);
    gc.scanRememberedSet(&tracer);

    while (tracer.hasWork()) {
        const cell = tracer.pop();
        gc.traceCell(&tracer, cell);
    }

    gc.processYoungWeakRefs();
    gc.resetNurseryFromSpace();
    gc.rebuildOrCleanRememberedSet();

    gc.phase = .idle;
}
```

### 8.4 晋升策略

对象晋升 old space 的条件：

```text
survived_minor_count >= 2
object size 超过 nursery large threshold
object 被 native pin
nursery to-space 不足
对象属于 known long-lived 类型:
  Function
  Shape
  ModuleRecord
  ServerBehavior
  compiled bytecode
```

默认参数：

```text
survival threshold:
  2 次 minor GC 后晋升

large young object threshold:
  4KB 或 8KB 起测

nursery 初始大小:
  512KB–4MB per worker

nursery 最大大小:
  根据 workload 和 RSS limit 自适应
```

---

## 9. Major GC

### 9.1 目标

major GC 负责 old space、large object space、weak structures、finalization。

第一生产目标：

```text
incremental mark
+ lazy/concurrent sweep
+ non-moving old space
```

后续增强：

```text
concurrent mark
+ concurrent sweep
+ selective evacuation
```

### 9.2 触发条件

```text
old allocated bytes since last major > threshold
heap committed bytes > soft limit
external memory > external threshold
RSS 接近 cgroup/container limit
minor GC promotion rate 高
fragmentation ratio 高
manual debug GC
idle-time opportunistic GC
```

### 9.3 Incremental Marking

阶段：

```text
idle
request_mark
mark_roots
mark_incremental
mark_drain
weak_fixpoint
finalize_mark
sweep
idle
```

伪代码：

```zig
pub fn startMajorGC(gc: *GC, reason: GCReason) void {
    if (gc.phase != .idle) return;

    gc.reason = reason;
    gc.phase = .mark_roots;
    gc.mark_epoch +%= 1;
    gc.mark_stack.clearRetainingCapacity();

    gc.scheduler.requestSlice(.soon);
}

pub fn majorSlice(gc: *GC, budget_ns: u64) void {
    const deadline = nowNs() + budget_ns;

    while (nowNs() < deadline) {
        switch (gc.phase) {
            .mark_roots => {
                gc.scanRoots(&gc.tracer);
                gc.phase = .mark_incremental;
            },

            .mark_incremental => {
                if (!gc.markSome(deadline)) return;
                gc.phase = .weak_fixpoint;
            },

            .weak_fixpoint => {
                if (!gc.processEphemerons(deadline)) return;
                gc.phase = .finalize_mark;
            },

            .finalize_mark => {
                gc.clearWeakRefs();
                gc.enqueueFinalizers();
                gc.phase = .sweep;
            },

            .sweep => {
                if (!gc.sweepSome(deadline)) return;
                gc.phase = .idle;
                gc.finishMajor();
                return;
            },

            else => return,
        }
    }
}
```

### 9.4 Sweeping

sweep 策略：

```text
lazy sweep:
  allocation 需要 page 时，优先 sweep 未处理 page。

incremental sweep:
  event-loop boundary 做小片 sweep。

concurrent sweep:
  GC worker 线程 sweep old pages，但 page 状态必须原子切换。
```

page 状态：

```zig
pub const PageState = enum(u8) {
    allocating,
    full,
    marking,
    needs_sweep,
    sweeping,
    swept,
    empty,
    decommitted,
};
```

sweep 逻辑：

```text
1. 遍历 page mark bitmap。
2. 未标记 cell:
   - 调用非 JS finalizer enqueue。
   - 放回 free list。
   - 扣除 live bytes。
3. page 全空:
   - 进入 empty list。
   - 根据策略 madvise/decommit。
4. page 碎片高:
   - 标记为 evacuation candidate。
```

---

## 10. Selective Evacuation / Optional Compaction

不建议第一版做全堆 compaction，但可以后续做选择性 evacuation。

适用场景：

```text
old space RSS 长期高于 live bytes 很多
大量 page live ratio < 20%
cgroup memory pressure 明显
server burst 后 RSS 不下降
```

约束：

```text
只移动可证明安全的 page。
pinned object 所在 page 不移动。
native 暴露过裸指针的 object 不移动。
JIT/code pointer/reference 不完整时不移动。
WeakMap/FinalizationRegistry fixpoint 未完成时不移动。
```

候选 page 条件：

```text
page.live_bytes / page.committed_bytes < 0.2
page.pinned_count == 0
page.native_exposed == false
page.evacuation_failures < N
```

算法：

```text
1. 选择 evacuation candidate pages。
2. 为 live object 分配新位置。
3. 安装 forwarding pointer。
4. 扫描 roots、old pages、remembered set，更新引用。
5. 释放 evacuated pages。
```

这个阶段可以显著改善 RSS，但复杂度明显高于 non-moving mark-sweep。因此它应该是 P4/P5 优化，而不是基础能力。

---

## 11. WeakRef、WeakMap、FinalizationRegistry

### 11.1 WeakRef

处理规则：

```text
mark 阶段不通过 WeakRef 强标记 target。
strong marking 完成后：
  target live:
    WeakRef 保持。
  target dead:
    WeakRef 清空。
```

### 11.2 WeakMap / Ephemeron

WeakMap 不能简单当普通 weak edge。

规则：

```text
WeakMap entry:
  key weak
  value conditionally live

如果 key 被 strong path 标记，则 value 必须被标记。
value 被标记后可能继续让其他 key/value 变 live。
因此需要 ephemeron fixpoint。
```

算法：

```zig
pub fn processEphemerons(gc: *GC, deadline: u64) bool {
    var changed = true;

    while (changed) {
        changed = false;

        for (gc.weak_maps.items) |wm| {
            for (wm.entries) |entry| {
                if (gc.isMarked(entry.key) and !gc.isMarkedValue(entry.value)) {
                    gc.markValue(entry.value);
                    changed = true;
                }

                if (nowNs() >= deadline) {
                    return false;
                }
            }
        }

        gc.drainMarkStackUntil(deadline);
    }

    return true;
}
```

### 11.3 FinalizationRegistry

规则：

```text
finalizer 不在 marker 线程执行。
finalizer 不在 sweeper 线程执行。
finalizer 不直接执行用户 JS。
finalizer job 投递到 VM job queue。
native cleanup job 投递到对应 uWS event-loop thread。
```

---

## 12. Native Resource 生命周期

GC 不负责及时关闭 socket/fd/timer。GC 只负责判断 JS wrapper 是否可达。

### 12.1 基本模型

```text
JS wrapper:
  受 GC 管理。

Native resource:
  Zig RAII/refcount/state machine 管理。

Persistent root:
  当 native resource 必须让 JS callback/promise 存活时使用。

WeakPersistent:
  作为 JS wrapper 死亡后的兜底清理。
```

结构示意：

```zig
pub const NativeResource = struct {
    ref_count: AtomicU32,
    state: enum { open, closing, closed },

    vm: *VM,
    loop: *EventLoop,

    js_wrapper: WeakPersistent,
    callback_root: ?Persistent,

    external_memory: ExternalMemoryToken,

    pub fn close(self: *NativeResource) void {
        if (self.state == .closed) return;

        self.state = .closing;

        if (self.callback_root) |*root| {
            root.deinit();
            self.callback_root = null;
        }

        self.external_memory.release();

        self.state = .closed;
        self.release();
    }
};
```

### 12.2 Finalizer 规则

```zig
fn finalizeSocketWrapper(rt: *Runtime, cell: *Cell) void {
    const wrapper: *JSSocket = @fieldParentPtr("cell", cell);

    if (wrapper.native) |resource| {
        resource.loop.enqueueCleanup(resource);
        wrapper.native = null;
    }
}
```

禁止：

```text
finalizer 中调用用户 JS
finalizer 中直接 uWS close/send/end
finalizer 中阻塞 I/O
finalizer 中申请大量内存
finalizer 中递归触发 GC
```

---

## 13. uWS 集成方案

### 13.1 每个 uWS thread 一个 VM

```text
Thread 1:
  uWS loop 1
  VM 1
  Heap 1

Thread 2:
  uWS loop 2
  VM 2
  Heap 2
```

禁止：

```text
VM 1 的 JSObject 被 VM 2 直接引用。
VM 1 的 Persistent handle 在 VM 2 释放。
跨线程直接操作 JS heap。
```

允许：

```text
structured clone
transferable ArrayBuffer
message passing
native shared resource + per-VM wrapper
```

### 13.2 HTTP Request 生命周期

```text
uWS callback begin
  enter HandleScope
  create Request wrapper
  create Response controller wrapper
  call JS handler
  drain immediate microtasks if required
  leave HandleScope
uWS callback end
  run small GC slice
```

关键规则：

```text
Request wrapper 默认 request-scoped。
如果 JS 将 Request/headers/body 逃逸到 Promise/timer/global:
  相关 JS object 必须进入 heap。
  native body/header buffer 必须 refcount。
  external memory 必须记账。

Response controller native resource 由 uWS response 生命周期约束。
JS wrapper 死亡不一定立即关闭 response。
response end/abort 后必须释放 strong roots。
```

### 13.3 WebSocket 生命周期

```text
connection open:
  create native WebSocketSession
  optional create JS wrapper
  server behavior callbacks 由 server root 持有

message:
  message buffer 进入 external memory accounting
  JS callback 参数用 Local handle
  若 buffer 被异步保留，则 backing store refcount + Persistent wrapper

send:
  如果 uWS copy 数据:
    不需要 pin backing store。
  如果 uWS 不 copy 数据:
    pin/refcount backing store 直到 send complete/backpressure release

close:
  release callback roots
  clear weak wrapper
  free external memory
```

WebSocket compression、send queue、backpressure buffer 都是 GC 外内存，不能只看 JS wrapper 大小。

### 13.4 Event-loop GC 调度点

推荐调度点：

```text
allocation slow path:
  必要时 minor GC / major slice / emergency GC

uWS callback return:
  drain microtasks
  run small GC slice

microtask drain 后:
  run small GC slice

event loop 即将 idle/poll 前:
  opportunistic GC slice

external memory 增长后:
  increase allocation debt
  maybe request major GC

RSS/cgroup pressure:
  force major mark + sweep + decommit
```

伪代码：

```zig
fn afterUWSCallback(vm: *VM) void {
    vm.runMicrotasks();

    if (vm.gc.scheduler.shouldRunSlice(.callback_boundary)) {
        vm.gc.runSlice(vm.gc.policy.callback_slice_budget_ns);
    }

    vm.gc.finalizers.runDeferredNativeCleanupBudgeted();
}

fn beforeEventLoopPoll(vm: *VM) void {
    if (vm.gc.scheduler.hasIdleDebt()) {
        vm.gc.runSlice(vm.gc.policy.idle_slice_budget_ns);
    }

    vm.gc.decommitQueue.processBudgeted();
}
```

---

## 14. GC Scheduler

### 14.1 Allocation Debt

每种 allocation 都产生 debt：

```text
young allocation:
  cheap debt

old allocation:
  medium debt

large object allocation:
  high debt

external memory allocation:
  weighted debt

promotion:
  high debt
```

示意：

```zig
pub fn onAlloc(gc: *GC, kind: AllocKind, bytes: usize) void {
    const weight = switch (kind) {
        .young => gc.policy.young_weight,
        .old => gc.policy.old_weight,
        .large => gc.policy.large_weight,
        .external => gc.policy.external_weight,
        .promotion => gc.policy.promotion_weight,
    };

    gc.allocation_debt += bytes * weight;

    if (gc.nursery.isFull()) {
        gc.scheduler.request(.minor, .urgent);
    }

    if (gc.allocation_debt > gc.policy.major_debt_threshold) {
        gc.scheduler.request(.major, .soon);
    }
}
```

### 14.2 Slice Budget

默认建议：

```text
callback boundary slice:
  100µs–500µs 起测

idle slice:
  1ms–5ms 起测

allocation slow path emergency:
  尽量 < 2ms
  极端 OOM 可允许 full stop-the-world

minor GC:
  目标 < 1ms
  nursery 过大时自动缩小

major incremental:
  多个 event-loop tick 完成
```

### 14.3 Trigger Policy

```zig
pub const GCPolicy = struct {
    nursery_initial_size: usize = 2 * MB,
    nursery_max_size: usize = 32 * MB,

    old_heap_growth_factor: f64 = 1.6,
    old_soft_limit: usize,

    external_soft_ratio: f64 = 0.5,
    rss_soft_limit: usize,
    rss_hard_limit: usize,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,

    young_weight: usize = 1,
    old_weight: usize = 4,
    large_weight: usize = 8,
    external_weight: usize = 8,
    promotion_weight: usize = 6,
};
```

---

## 15. 内存控制策略

### 15.1 Nursery 自适应

根据 survival rate 调整 nursery：

```text
survival rate 低:
  短命对象多。
  可以扩大 nursery，提高吞吐。

survival rate 高:
  对象经常晋升。
  缩小 nursery，避免 minor pause 和 promotion storm。

minor pause 超预算:
  缩小 nursery。

QPS 高且 RSS 充足:
  扩大 nursery。

RSS 接近 limit:
  缩小 nursery，增加 major/sweep/decommit。
```

公式示意：

```zig
fn tuneNursery(gc: *GC) void {
    const survival = gc.stats.last_minor_survival_rate;
    const pause = gc.stats.last_minor_pause_ns;

    if (pause > gc.policy.minor_pause_target_ns) {
        gc.nursery.shrink();
    } else if (survival < 0.10 and gc.rssBelowSoftLimit()) {
        gc.nursery.grow();
    } else if (survival > 0.35) {
        gc.nursery.shrink();
    }
}
```

### 15.2 Old Space Page Decommit

```text
sweep 后 page 全空:
  先进入 empty page cache。

empty page cache 超过阈值:
  madvise(DONTNEED) 或 munmap。

RSS pressure:
  立即 decommit empty pages。

低延迟模式:
  保留少量 hot empty pages，减少 mmap/madvise 抖动。

低内存模式:
  更积极 decommit。
```

### 15.3 Fragmentation 指标

```text
page_live_ratio = live_bytes / committed_bytes
space_fragmentation = free_bytes / committed_bytes
reclaimable_ratio = empty_page_bytes / committed_bytes
old_effective_overhead = committed_old_bytes / live_old_bytes
```

报警条件：

```text
old_effective_overhead > 2.0 持续多轮 GC
RSS 高但 live bytes 低
empty pages 未及时 decommit
large object space 增长但 live large objects 不增长
```

---

## 16. Safepoint 设计

### 16.1 Safepoint 位置

```text
allocation slow path
function prologue
loop back edge
call JS function 前后
call native function 前后
await suspension
microtask boundary
uWS callback return
JIT OSR exit
exception throw/catch
```

### 16.2 Safepoint 职责

```text
检查 GC request。
保存 VM frame 状态。
暴露 precise roots。
允许 minor GC。
允许 major GC slice。
处理中断、stack overflow、termination。
```

示意：

```zig
pub inline fn safepoint(vm: *VM) void {
    if (!vm.interrupts.hasPending()) return;

    if (vm.gc.scheduler.needsSafepoint()) {
        vm.gc.handleSafepoint();
    }

    if (vm.termination_requested) {
        vm.throwTermination();
    }
}
```

---

## 17. JIT / Interpreter Root 支持

### 17.1 Interpreter

Interpreter 阶段较简单：

```text
VM operand stack 是 precise root。
CallFrame 保存 bytecode register range。
每个 register 知道是否是 JSValue。
```

结构：

```zig
pub const CallFrame = struct {
    function: JSValue,
    lexical_env: JSValue,
    registers: []JSValue,
    return_pc: usize,
};
```

GC 扫描：

```zig
fn traceCallFrame(tracer: *Tracer, frame: *CallFrame) void {
    tracer.edgeValue(&frame.function);
    tracer.edgeValue(&frame.lexical_env);

    for (frame.registers) |*reg| {
        tracer.edgeValue(reg);
    }
}
```

### 17.2 JIT

JIT 阶段必须引入 stack map。

```text
每个 safepoint pc 对应:
  哪些 register 是 JSValue
  哪些 stack slot 是 JSValue
  哪些 machine register 是 tagged pointer
  deopt metadata
```

没有 stack map 前，不要让 JIT 代码在任意点触发 moving young GC。

---

## 18. String / Atom / Shape 策略

### 18.1 String

```text
small string:
  可以 inline。

medium string:
  JS heap cell + external/inline payload。

large string:
  external backing store。

rope string:
  trace left/right child。
  flatten 时产生 external memory debt。
```

策略：

```text
interned string 进入 atom table。
atom table 是 weak/strong 混合结构。
内置字符串 immortal。
request 临时字符串优先 young。
```

### 18.2 Shape / Hidden Class

```text
shape 通常长寿。
shape 可以直接 old allocation。
shape transition table 使用 weak edges，避免无限增长。
hot shape 可 immortal 或 old pinned。
```

### 18.3 Bytecode / Code Block

```text
compiled bytecode old allocation。
JIT code memory 不放 JS heap。
JIT code object 由 GC trace 元数据和 native executable memory token 连接。
code memory 必须 external accounting。
```

---

## 19. ArrayBuffer / TypedArray

### 19.1 结构

```text
JSArrayBuffer:
  GC cell
  points to BackingStore

BackingStore:
  refcounted native allocation
  external memory token
  optional finalizer
  optional shared/transferable state
```

示意：

```zig
pub const BackingStore = struct {
    ref_count: AtomicU32,
    ptr: [*]u8,
    len: usize,
    token: ExternalMemoryToken,
    owner_vm: *VM,

    pub fn retain(self: *BackingStore) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *BackingStore) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.token.release();
            allocator.free(self.ptr[0..self.len]);
            allocator.destroy(self);
        }
    }
};
```

### 19.2 WebSocket send 规则

```text
send(buffer):
  如果 uWS copy:
    不需要 pin backing store。

  如果 uWS 不 copy:
    BackingStore.retain()
    加入 pending send
    send complete / aborted 后 release()
```

禁止依赖 JS wrapper 存活来保证 native send buffer 存活。

---

## 20. Error Handling 与 OOM 策略

### 20.1 Soft OOM

```text
allocation 失败前:
  minor GC
  major mark/sweep
  decommit empty pages
  release deferred native cleanup
  trim external caches
```

### 20.2 Hard OOM

```text
如果仍失败:
  抛 JS RangeError / OutOfMemoryError 类错误。
  对不可恢复 VM 状态，标记 VM poisoned。
  拒绝继续执行用户 JS。
```

### 20.3 Container Awareness

```text
读取 cgroup memory limit。
RSS > soft limit:
  提高 GC 频率。
  aggressive decommit。
  降低 nursery max。

RSS > hard limit:
  emergency full GC。
  清理 caches。
  拒绝大 allocation。
```

---

## 21. 并发设计

### 21.1 第一版：单线程 Incremental

```text
所有 marking/sweeping 在 mutator thread 上切片执行。
简单、可调试、风险低。
```

### 21.2 第二版：Concurrent Mark

```text
GC worker 后台扫描 old graph。
mutator 继续运行。
write barrier 维护 tri-color invariant。
mark stack 使用 lock-free 或 work-stealing queue。
```

要求：

```text
mark bits atomic 或 page-local synchronized。
object header state 更新要避免 data race。
trace 期间 object layout 必须稳定。
shape/table resize 要有 barrier 和 safepoint。
```

### 21.3 Concurrent Sweep

```text
sweeper 只能处理不可被当前 allocator 修改的 page。
page state 从 needs_sweep -> sweeping -> swept 原子切换。
allocator 只从 swept page 分配。
```

---

## 22. API 设计

### 22.1 分配 API

```zig
pub fn allocCell(
    vm: *VM,
    comptime T: type,
    init: anytype,
) !*T {
    const size = @sizeOf(T);

    if (shouldAllocateOld(T)) {
        return vm.gc.allocOld(T, init);
    }

    return vm.gc.allocYoung(T, init) catch {
        try vm.gc.collectMinor(.nursery_full);
        return vm.gc.allocYoung(T, init);
    };
}
```

### 22.2 Root API

```zig
pub fn makePersistent(vm: *VM, value: JSValue) !Persistent {
    return vm.roots.createPersistent(value);
}

pub fn makeWeakPersistent(
    vm: *VM,
    value: JSValue,
    callback: WeakCallback,
) !WeakPersistent {
    return vm.roots.createWeak(value, callback);
}
```

### 22.3 Native Resource API

```zig
pub fn attachNativeResource(
    vm: *VM,
    wrapper: JSValue,
    resource: *NativeResource,
    external_bytes: usize,
) void {
    resource.js_wrapper = vm.roots.createWeak(wrapper, nativeWrapperDead);
    resource.external_memory = vm.gc.reportExternalAlloc(external_bytes);
}
```

### 22.4 Embedding API

嵌入 Zig 项目的 public API 不强制暴露 `HandleScope`。`HandleScope` 可以作为 VM 内部 root 管理机制存在，但外部默认应使用 owning handle：

```zig
var rt = try zjs.JSRuntime.init(allocator, .{});
defer rt.deinit();

var ctx = try zjs.JSContext.init(&rt, .{});
defer ctx.deinit();

var value = try ctx.eval("1 + 1", .{});
defer value.deinit();
```

语义：

```text
core.Value / RawValue:
  VM 内部 tagged value。
  热路径使用。
  不携带 runtime/context。

zjs.JSValue:
  public owned rooted handle。
  释放的是 root/handle，不直接释放 JS 对象。

Persistent:
  跨 event-loop tick、timer、async continuation、native callback 长期持有。

HandleScope:
  VM 内部批量管理 local roots 的机制，不作为嵌入 API 的必选层。
```

---

## 23. 调参模式

### 23.1 Throughput Mode

适合高 QPS、内存充足的 HTTP server。

```text
nursery 较大
minor GC 较少
idle decommit 较保守
major GC 更多依赖 concurrent
external memory soft trigger
```

建议：

```text
nursery_initial_size: 4MB
nursery_max_size: 64MB
old_heap_growth_factor: 1.8
callback_slice_budget: 200µs
idle_slice_budget: 2ms
```

### 23.2 Low RSS Mode

适合容器、serverless、边缘节点。

```text
nursery 较小
old sweep 更积极
empty page 快速 madvise/decommit
external memory hard trigger
RSS/cgroup aware
```

建议：

```text
nursery_initial_size: 512KB–2MB
nursery_max_size: 8MB–16MB
old_heap_growth_factor: 1.3
callback_slice_budget: 300µs
idle_slice_budget: 5ms
external_weight: high
```

### 23.3 Low Latency Mode

适合 WebSocket、实时推送、交易、游戏。

```text
minor pause 严格控制
major 全 incremental/concurrent
finalizer 完全 deferred
callback boundary 小 slice
idle 时多做
```

建议：

```text
minor_pause_target: < 1ms
callback_slice_budget: 100µs–300µs
idle_slice_budget: 1ms–3ms
avoid emergency full GC
nursery 根据 pause 自动缩小
```

---

## 24. 监控指标

必须暴露：

```text
heap_live_bytes
heap_committed_bytes
young_live_bytes
young_committed_bytes
old_live_bytes
old_committed_bytes
large_object_bytes
external_bytes
rss_bytes
cgroup_limit_bytes

minor_gc_count
major_gc_count
minor_pause_ns_p50/p95/p99
major_pause_ns_p50/p95/p99
incremental_slice_ns_p50/p95/p99
concurrent_mark_time_ns
sweep_time_ns

nursery_survival_rate
promotion_rate
copied_young_objects / copied_young_bytes
remembered_set_size
dirty_card_count
mark_stack_peak
weak_ref_count
finalizer_queue_length

old_fragmentation_ratio
empty_page_bytes
decommitted_bytes
allocation_debt
event_loop_delay_p99
```

调试 API：

```js
BunLike.gc.stats()
BunLike.gc.force()
BunLike.gc.forceMajor()
BunLike.gc.setMode("throughput" | "low-rss" | "low-latency")
BunLike.gc.heapSnapshot()
```

---

## 25. 测试方案

### 25.1 正确性测试

```text
每次 allocation 后强制 GC。
每次 property write 后随机 GC。
每个 uWS callback 返回后强制 GC。
Promise/microtask 中随机 GC。
WeakMap/WeakRef/FinalizationRegistry stress。
ArrayBuffer transfer/send/backpressure stress。
```

### 25.2 Fuzz

```text
JS parser fuzz
bytecode execution fuzz
object graph mutation fuzz
WeakMap ephemeron fuzz
async Promise fuzz
uWS HTTP/WebSocket lifecycle fuzz
native resource close/abort fuzz
```

### 25.3 内存测试

```text
steady-state HTTP QPS
burst traffic 后 RSS 是否下降
WebSocket 长连接 1k/10k/100k
large ArrayBuffer send
stream cancellation
fetch/body abort
timer create/cancel
Promise chain leak detection
module cache stress
```

### 25.4 工具

```text
ASan
TSan
UBSan
Valgrind / heaptrack
Linux perf
eBPF allocator tracing
custom heap verifier
deterministic GC seed
```

### 25.5 Heap Verifier

每轮 debug GC 后验证：

```text
所有 heap pointer 指向合法 cell。
所有 old -> young edge 在 remembered set/card table 中。
所有 black -> white edge 不存在。
所有 forwarding pointer 已更新。
所有 free-list cell 不可达。
所有 external memory token 没有重复 release。
所有 Persistent root 可释放。
```

---

## 26. 分阶段实现路线

### P0：基础非移动 STW GC

目标：正确性。

```text
page allocator
CellHeader
TypeInfo.trace
precise VM roots
HandleScope
Persistent / WeakPersistent
old-space mark-sweep
large object space
external memory accounting
deferred finalizer queue
heap verifier
```

此阶段可以跑 Test262 子集和简单 HTTP server。

### P1：分代 GC

目标：吞吐。

```text
nursery bump allocation
minor GC
young copying
forwarding pointer
promotion
remembered set
card table
post-write barrier
nursery tuning
```

此阶段开始适合 HTTP benchmark。

### P2：Incremental Major GC

目标：降低 p99 pause。

```text
incremental marking
mark stack slicing
incremental sweep
callback boundary slice
idle slice
allocation debt scheduler
event-loop integration
```

此阶段开始适合长期 server workload。

### P3：Concurrent Mark/Sweep

目标：降低 major GC 对 event loop 的影响。

```text
GC worker
atomic mark bits
concurrent mark stack
concurrent sweep page states
mutator barrier hardening
safepoint handshake
```

### P4：RSS 优化

目标：长期内存稳定。

```text
page decommit
cold page trimming
large object trimming
external memory pressure
cgroup awareness
fragmentation metrics
selective evacuation prototype
```

### P5：JIT 完整支持

目标：高性能 JS 执行。

```text
JIT stack maps
safepoint metadata
deopt root map
inline allocation fast path
JIT write barriers
JIT call boundary GC protocol
```

### 当前中间态 TODO

当前实现应先保持为可构建、可验证的中间态。已落地的方向包括：

```text
提交边界（2026-06-03）：
  - 当前状态是可用的中间态，不是完整的新 GC 终态。
  - 最近一次验证：zig build test --summary all，967/967 tests passed。
  - 最近一次验证：zig build zjs --summary all passed。
  - 最近一次验证：git diff --check passed。
  - 当前 build graph 不包含 smoke step；zig build smoke --summary all 会返回 no step named 'smoke'。
  - 后续大项按下面 TODO 推进，先完成大项修改，再统一 test / fix。
```

```text
HandleScope / Persistent / WeakPersistent 基础 root；Local / Persistent handles 可从移动后 root slot 重新取回 Object，WeakPersistent identity 会随移动更新；外部 host-owned by-value object root 注册时 dup+pin，注销/clear 时 unpin+free，避免宿主 value copy 在 moving nursery 后失效。
old -> young remembered set / dirty card barrier。
external memory accounting、GC request 与 external token registry 审计（包含 SharedBufferStore owner token）。
minor GC 默认 strict/full-copying nursery：root/remembered tracing 访问到的 young Object 会复制到 old allocation，untraced nursery entries 会释放；final pass 原地晋升 fallback 已删除。full-copying 路径已覆盖 survivor 复制、untraced nursery entry 释放、untraced nursery object graph 析构释放、untraced owner 析构时 stale child slot release 转发到 moved survivor；scheduler、var-ref、Promise payload、mapped arguments barrier 测试已迁移到 root/handle discipline。
FunctionBytecode 已明确为 non-moving old/large bytecode space，即使调用方请求 young 也不会进入 nursery。
moving nursery 的 forwarding table 只在单次 minor collection 内有效：用于更新 root/slot/handle/weak identity，并在 final pass 析构期间转发 stale child release；collection 成功结束后立即释放旧 Object shadow 并清空 table，不再保留到 runtime deinit 作为 stale raw release 兼容层。
GC stats 使用 `copied_young_*` 量化 moving nursery survivor copy；in-place young promotion 路径与对应指标已删除。
dense array elements、function captures、generator frame lists、module namespace cells、Promise reaction list、Promise reaction promise/callback-result active roots、dequeued Promise job value root、async await popped value root、thenable resolving-function roots、Promise reaction job handler/payload/resolve/reject roots、Promise combinator state/values/payload roots、async iterator dispose result root、live-key WeakMap entry value、active/pending FinalizationRegistry held/token slots、class payload value/object hooks、dequeued job argv active root 已有 moving minor slot rewrite 覆盖；WeakMap entry minor visitor 按 live key 条件访问 value，FinalizationRegistry cell visitor 按 keepsHeldValuesAlive 条件访问 held/token。
nursery tuning。
large object classification。
old/large page metadata allocator、size-class page、free-list、allocation bitmap 与 mark bitmap。
major GC 当前已拆出第一个 P2 中间态：STW cycle-removal mark backend 完成后进入 `.sweep` phase，old/large page metadata 通过 sweep cursor 按 scheduler budget 进行 lazy/page-slice sweep；active sweep 可在 callback boundary / idle poll 继续推进，不再由 pollGC 的 major mark 路径 sweep-all。
GC scheduler request、callback/idle/safepoint 入口。
native pin API、RSS/cgroup pressure request、deferred native cleanup queue（external host / std file close / class payload finalizer）。
heap verifier 覆盖 heap/live bytes、page slot/bitmap/free-list accounting、pin metadata、remembered set。
```

剩余 TODO：

```text
P0:
  - 如需让对象物理地址也来自 GC page arena，将 Object / FunctionBytecode allocation ownership 从 MemoryAccount create/alloc 迁移到 page allocator-backed blocks。
  - 当前 old/large page metadata allocator 已经是 GC accounting / verifier / sweep cursor 的 authoritative source；物理 payload 地址仍由 MemoryAccount 提供。

P1:
  - 继续补齐 HandleScope/Persistent/root slot discipline，确保代码不在 minor GC 后访问未 root 的 raw `*Object`。
  - 为移动 young object 继续补齐 collection 内所有 root、slot、handle、dirty card 更新与验证。

P2:
  - 将 major GC 的 mark roots / mark some / weak fixpoint 从当前 STW cycle-collector backend 继续拆成真正 incremental slice。
  - 继续让 callback boundary / idle poll 按时间预算推进 active major mark/weak/sweep slice；当前已覆盖 active sweep slice。
  - 继续扩展 lazy sweep/page recovery 到更完整的 sweep accounting、failure recovery 和 final completion gate。

P3:
  - 增加 GC worker、atomic mark bits、concurrent mark stack、concurrent sweep page states。
  - 增强 incremental marking barrier，保证 black -> white 写入在并发/增量标记中正确 shade。
  - 增加 safepoint handshake，支持未来 worker/JIT 并发协议。

P4:
  - 实现真实 page decommit / madvise / cold page trimming，而不是仅记录 logical decommitted bytes。
  - 增加 large object tail trimming 和 RSS/cgroup pressure 下的强制 decommit 策略。
  - 做 selective evacuation prototype，并只在 pinned / weak / finalizer 约束满足时启用。

P5:
  - 增加 JIT stack maps、deopt root map、inline allocation fast path 和 JIT write barrier。
  - 禁止没有 stack map 的 JIT 帧触发 moving nursery GC。
```

---

## 27. 推荐默认配置

```zig
pub const DefaultGCConfig = struct {
    mode: GCMode = .balanced,

    nursery_initial_size: usize = 2 * MB,
    nursery_min_size: usize = 512 * KB,
    nursery_max_size: usize = 32 * MB,

    minor_pause_target_ns: u64 = 1_000_000,

    old_heap_growth_factor: f64 = 1.6,
    old_fragmentation_trigger: f64 = 0.45,

    large_object_threshold: usize = 8 * KB,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,

    external_weight: usize = 8,
    promotion_weight: usize = 6,

    decommit_empty_pages: bool = true,
    retain_hot_empty_pages: usize = 64,

    enable_concurrent_mark: bool = true,
    enable_concurrent_sweep: bool = true,
    enable_selective_evacuation: bool = false,
};
```

---

## 28. 关键工程规则

### 28.1 必须遵守

```text
所有跨 allocation 的 JSValue 必须在 handle 中。
所有 old -> young 写入必须经过 write barrier。
所有 native/off-heap allocation 必须 reportExternalAlloc。
所有 native/off-heap free 必须 reportExternalFree。
所有 async callback root 必须在完成/取消/abort 时释放。
所有 finalizer 必须 deferred。
所有 uWS socket 操作必须回到对应 event-loop thread。
```

### 28.2 禁止

```text
Zig struct 长期保存裸 *JSObject。
GC 线程直接调用 uWS API。
finalizer 执行用户 JS。
native resource 只靠 GC 关闭。
ArrayBuffer backing store 不记 external memory。
跨 worker 直接传 JS object。
在没有 stack map 的 JIT 代码中触发 moving nursery GC。
```

---

## 29. 最终架构摘要

```text
                ┌─────────────────────────────┐
                │        uWS Event Loop        │
                └──────────────┬──────────────┘
                               │
                               ▼
                ┌─────────────────────────────┐
                │             VM              │
                ├─────────────────────────────┤
                │ Root Registry               │
                │ Handle Scopes               │
                │ Persistent / Weak Handles   │
                ├─────────────────────────────┤
                │ GC Scheduler                │
                │ Allocation Debt             │
                │ External Memory Accounting  │
                ├─────────────────────────────┤
                │ Nursery                     │
                │   bump alloc + copying GC   │
                ├─────────────────────────────┤
                │ Old Space                   │
                │   non-moving mark-sweep     │
                │   incremental/concurrent    │
                ├─────────────────────────────┤
                │ Large Object Space          │
                │ External Backing Stores     │
                └─────────────────────────────┘
```

最终推荐：

```text
MVP:
  non-moving STW mark-sweep
  + precise roots
  + handles
  + external memory accounting

Production v1:
  copying nursery
  + non-moving old space
  + incremental major GC
  + uWS event-loop scheduling
  + deferred finalizers

Production v2:
  concurrent mark/sweep
  + page decommit
  + RSS/cgroup pressure handling
  + optional selective evacuation
  + JIT stack maps / JIT barriers
```

一句话概括：

> 对 Zig + uWS + Bun-like JS runtime，最佳 GC 不是一开始做全堆压缩，而是用 **copying nursery 解决吞吐与年轻代碎片，用 non-moving old space 降低 native 嵌入复杂度，用 incremental/concurrent old GC 控制延迟，用 external memory accounting 控制真实 RSS**。

---

## 30. 参考资料

- Bun Runtime Docs: https://bun.com/docs/runtime
- Bun v1.2.2 Release Notes: https://bun.com/blog/bun-v1.2.2
- Bun v1.3.10 Release Notes: https://bun.com/blog/bun-v1.3.10
- WebKit: Understanding GC in JSC from Scratch: https://webkit.org/blog/12967/understanding-gc-in-jsc-from-scratch/
- WebKit: Introducing Riptide: https://webkit.org/blog/7122/introducing-riptide-webkits-retreating-wavefront-concurrent-garbage-collector/
- V8: Trash talk: the Orinoco garbage collector: https://v8.dev/blog/trash-talk
- uWebSockets READMORE: https://github.com/uNetworking/uWebSockets/blob/master/misc/READMORE.md
