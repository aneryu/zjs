# Stack Bytecode VM 是否需要改成 Register / Accumulator Bytecode Interpreter

面向场景：**Zig 编写的 JS 引擎 / JS runtime，当前已经实现 stack bytecode VM，目标类似 Bun，网络层适配 uWS，用于 HTTP/WebSocket server。**

结论先行：

```text
不需要“改成 bytecode interpreter”。

你当前的 stack bytecode VM 本身已经是 bytecode interpreter。

真正需要评估的问题是：
是否要从 stack bytecode interpreter
迁移到 register / accumulator bytecode interpreter。
```

建议：

```text
短期：保留现有 stack bytecode VM。
中期：把它增强成成熟的 bytecode interpreter，补齐 metadata、IC、GC stack map、exception table、profiling。
长期：如果准备做 baseline JIT 或 profiler 证明 dispatch/stack traffic 是瓶颈，再迁移到 accumulator/register bytecode。
```

更具体地说：

```text
当前最优路线：
  stack bytecode interpreter
  + metadata side table
  + Shape / HiddenClass object model
  + get_by_id / put_by_id inline cache
  + call inline cache
  + precise GC stack scanning
  + exception/source/liveness tables
  + uWS callback boundary safepoint

后续演进路线：
  stack bytecode
  -> stack + accumulator hybrid
  -> accumulator/register bytecode
  -> baseline JIT
```

---

## 1. 概念澄清

### 1.1 Stack bytecode VM 已经是 bytecode interpreter

如果当前 VM 是这样运行的：

```text
source code
  -> parser / compiler
  -> bytecode
  -> VM loop dispatch opcode
  -> 执行 opcode handler
```

那么它已经是 **bytecode interpreter**。

常见 interpreter 形态包括：

```text
AST interpreter:
  直接解释 AST 节点。

Stack bytecode interpreter:
  解释 stack-machine bytecode。

Register bytecode interpreter:
  解释 register-machine bytecode。

Accumulator bytecode interpreter:
  解释带隐式 accumulator 的 bytecode。
```

所以，问题不是：

```text
stack bytecode VM 要不要改成 bytecode interpreter？
```

而是：

```text
stack bytecode interpreter 要不要改成 register / accumulator bytecode interpreter？
```

---

## 2. 当前建议

### 2.1 不要现在重写 bytecode 格式

如果现在已经有可运行的 stack bytecode VM，不建议立即推倒重写成 register VM。

原因：

```text
1. 当前阶段最大性能差距通常不在 stack bytecode 本身。
2. JS runtime 的主要复杂度在对象模型、IC、GC、Promise、module、host integration。
3. 过早重写 bytecode 会打断 object model、GC、uWS bridge 的稳定化。
4. register bytecode 的 compiler、liveness、debug、exception、JIT metadata 都更复杂。
5. 没有 profiler 数据前，很难证明重写 bytecode 格式是收益最高的优化。
```

现在更应该优先做：

```text
1. CodeBlock 结构化
2. bytecode metadata side table
3. Shape / HiddenClass object model
4. get_by_id / put_by_id inline cache
5. call inline cache
6. array elements kind
7. exception table
8. source position table
9. GC stack map / liveness table
10. bytecode verifier
11. uWS callback boundary safepoint
12. external memory accounting
```

---

## 3. Stack VM、Register VM、Accumulator VM 对比

### 3.1 Stack bytecode VM

典型 bytecode：

```text
get_local   0          ; push local[0]
get_by_id   "x", ic0   ; pop base, push base.x
get_local   0          ; push local[0]
get_by_id   "y", ic1   ; pop base, push base.y
add         arith0     ; pop rhs/lhs, push result
return                  ; pop result
```

优点：

```text
compiler 简单。
opcode operand 少。
bytecode 编码紧凑。
表达式求值自然。
早期实现速度快。
debug 容易。
适合先跑通 JS 语义。
```

缺点：

```text
指令数量可能偏多。
dispatch 次数较多。
push/pop/dup/swap 容易膨胀。
JIT lowering 时需要模拟 operand stack。
GC liveness 需要计算每个 pc 的 stack depth 和 slot 状态。
优化器需要从 stack effect 反推数据流。
```

### 3.2 Register bytecode VM

典型 bytecode：

```text
get_by_id   r1, r0, "x", ic0
get_by_id   r2, r0, "y", ic1
add         r3, r1, r2, arith0
return      r3
```

优点：

```text
数据流显式。
指令数量通常更少。
适合 baseline JIT。
适合 SSA IR 构建。
GC liveness 更接近 register bitmap。
优化器更容易分析。
```

缺点：

```text
compiler 更复杂。
需要寄存器分配或 virtual register 分配。
bytecode operand 更多。
bytecode 体积可能变大。
debug/exception/OSR metadata 更复杂。
早期开发成本更高。
```

### 3.3 Accumulator bytecode VM

典型 bytecode：

```text
load_local  0              ; acc = local[0]
get_by_id   "x", ic0       ; acc = acc.x
store_local 1              ; local[1] = acc

load_local  0              ; acc = local[0]
get_by_id   "y", ic1       ; acc = acc.y
add_local   1, arith0      ; acc = local[1] + acc
return_acc
```

优点：

```text
比纯 stack VM 少 push/pop。
比纯 register VM compiler 简单。
operand 数量相对可控。
适合后续 baseline JIT。
表达式链执行效率较好。
```

缺点：

```text
仍需要 locals/register slots。
compiler 比 stack VM 复杂。
需要处理 accumulator live range。
迁移需要改 emitter 和 interpreter。
```

### 3.4 推荐取舍

| 方案 | 当前开发成本 | 解释器吞吐 | GC liveness | IC 集成 | JIT 预留 | 当前建议 |
|---|---:|---:|---:|---:|---:|---|
| Stack bytecode | 低 | 中 | 中 | 好 | 中 | 继续保留 |
| Stack + metadata | 中 | 中到高 | 好 | 很好 | 中 | 立即做 |
| Stack + accumulator | 中 | 高 | 好 | 很好 | 好 | 中期做 |
| Register bytecode | 高 | 高 | 很好 | 很好 | 很好 | JIT 前再做 |
| 直接 JIT | 很高 | 高 | 很复杂 | 很好 | 已进入 JIT | 不建议现在做 |

---

## 4. 为什么当前最大瓶颈通常不是 stack bytecode

对 JS runtime，尤其是 Bun-like server runtime，早期性能瓶颈通常在这些地方：

```text
property access:
  obj.x / req.url / headers.foo / res.status

function call:
  JS function call
  native builtin call
  callback call

object allocation:
  request wrapper
  response object
  closure
  Promise reaction

array/string:
  Array elements kind
  string concat
  substring
  UTF-16/Latin1 representation

async/runtime:
  Promise
  microtask queue
  async continuation
  stream / WebSocket callback

GC:
  root scanning
  write barrier
  external memory accounting
  finalizer queue
```

换句话说，下面这个 hot path：

```js
server.fetch = req => {
  return new Response("hello " + req.url);
};
```

真正需要快的是：

```text
uWS callback -> JS handler call
Request wrapper allocation
req.url get_by_id IC
string concat fast path
Response constructor native builtin
body backing store external memory accounting
microtask drain
GC slice
```

其中 stack bytecode dispatch 只是其中一部分。没有 IC 的 `req.url` 会比 stack/register bytecode 差异更致命。

---

## 5. 当前 stack bytecode VM 应该补齐什么

## 5.1 CodeBlock

不要把 bytecode 当成裸 `[]u8`。需要把它包装成 `CodeBlock`。

```zig
pub const CodeBlock = struct {
    bytecode: []const u8,
    constants: []JSValue,

    metadata: MetadataTable,

    max_stack_depth: u32,
    local_count: u32,
    argument_count: u32,

    exception_table: []ExceptionHandler,
    source_positions: SourcePositionTable,
    stack_maps: StackMapTable,

    hot_call_count: u32,
    hot_loop_count: u32,

    flags: CodeBlockFlags,
};
```

设计原则：

```text
bytecode stream 尽量只读。
运行时可变信息放 metadata side table。
IC/profile/counter 不直接塞入 instruction stream。
GC/JIT/debugger 需要的表都挂在 CodeBlock 上。
```

---

## 5.2 Metadata side table

每个需要 runtime feedback 的 opcode 都应该引用 metadata id。

```zig
pub const MetadataTable = struct {
    get_by_id: []GetByIdIC,
    put_by_id: []PutByIdIC,
    get_by_value: []GetByValueIC,
    put_by_value: []PutByValueIC,

    call: []CallIC,
    construct: []ConstructIC,

    arith: []ArithProfile,
    compare: []CompareProfile,
    branch: []BranchProfile,
};
```

例如 bytecode：

```text
get_by_id "url", metadata_id=3
```

解释器执行时：

```zig
const ic = &frame.code.metadata.get_by_id[metadata_id];
const result = getByIdWithIC(vm, base, key, ic);
```

好处：

```text
IC 可变，但 bytecode 不变。
后续 baseline JIT 可以复用 metadata。
profiling 数据和 bytecode 生命周期一致。
heap snapshot/debugger 可以从 CodeBlock 读取 profiling。
bytecode 可共享或缓存。
```

---

## 5.3 Stack effect table

Stack VM 必须有完整 stack effect 描述。

```zig
pub const StackEffect = struct {
    pops: u8,
    pushes: u8,
    variable: bool,
};

pub fn stackEffect(op: OpCode) StackEffect {
    return switch (op) {
        .load_undefined => .{ .pops = 0, .pushes = 1, .variable = false },
        .load_null      => .{ .pops = 0, .pushes = 1, .variable = false },
        .load_true      => .{ .pops = 0, .pushes = 1, .variable = false },
        .load_false     => .{ .pops = 0, .pushes = 1, .variable = false },
        .load_const     => .{ .pops = 0, .pushes = 1, .variable = false },

        .get_local      => .{ .pops = 0, .pushes = 1, .variable = false },
        .set_local      => .{ .pops = 1, .pushes = 0, .variable = false },

        .get_by_id      => .{ .pops = 1, .pushes = 1, .variable = false },
        .put_by_id      => .{ .pops = 2, .pushes = 0, .variable = false },

        .add            => .{ .pops = 2, .pushes = 1, .variable = false },
        .sub            => .{ .pops = 2, .pushes = 1, .variable = false },
        .mul            => .{ .pops = 2, .pushes = 1, .variable = false },
        .div            => .{ .pops = 2, .pushes = 1, .variable = false },

        .call           => .{ .pops = 0, .pushes = 1, .variable = true },
        .construct      => .{ .pops = 0, .pushes = 1, .variable = true },

        .return_        => .{ .pops = 1, .pushes = 0, .variable = false },
        .throw_         => .{ .pops = 1, .pushes = 0, .variable = false },

        else => unreachable,
    };
}
```

这个表用于：

```text
bytecode verifier
max_stack_depth calculation
GC stack map generation
exception unwinding
debugger stack inspection
baseline JIT lowering
```

---

## 5.4 Bytecode verifier

Stack bytecode 必须做 verifier，否则很容易在 compiler bug 时造成 VM 崩溃。

Verifier 检查：

```text
每条指令操作数合法。
pc 不越界。
branch target 是合法 instruction boundary。
stack depth 不为负。
stack depth 不超过 max_stack_depth。
所有 basic block merge 点 stack depth 一致。
return/throw 后不可达代码可识别。
exception handler stack depth 合法。
metadata id 合法。
constant index 合法。
local index 合法。
```

示意：

```zig
pub fn verifyCodeBlock(code: *CodeBlock) !void {
    var worklist = BasicBlockWorklist.init();
    var states = try allocateVerificationStates(code);

    worklist.push(.{ .pc = 0, .stack_depth = 0 });

    while (worklist.pop()) |state| {
        var pc = state.pc;
        var depth = state.stack_depth;

        while (pc < code.bytecode.len) {
            const op = decodeOp(code.bytecode, &pc);
            const effect = stackEffect(op.code);

            if (!effect.variable) {
                if (depth < effect.pops) return error.StackUnderflow;
                depth = depth - effect.pops + effect.pushes;
                if (depth > code.max_stack_depth) return error.StackOverflow;
            } else {
                depth = computeVariableStackEffect(op, depth) catch return error.BadStackEffect;
            }

            switch (op.code) {
                .jump => {
                    try mergeTargetState(&states, op.target, depth);
                    break;
                },
                .jump_if_true, .jump_if_false => {
                    try mergeTargetState(&states, op.target, depth);
                    continue;
                },
                .return_, .throw_ => break,
                else => continue,
            }
        }
    }
}
```

---

## 5.5 Exception table

不要用 VM stack 本身硬编码 try/catch。每个 CodeBlock 应有 exception table。

```zig
pub const ExceptionHandler = struct {
    start_pc: u32,
    end_pc: u32,
    handler_pc: u32,
    finally_pc: ?u32,
    stack_depth: u32,
    lexical_env_depth: u32,
};
```

抛异常时：

```text
1. vm.exception = thrown value
2. 当前 frame 查 exception_table
3. 找到覆盖 pc 的 handler
4. unwind operand stack 到 handler stack_depth
5. 恢复 lexical env depth
6. pc = handler_pc
7. push exception 或放入 catch binding
8. 继续解释
```

---

## 5.6 Source position table

用于错误栈、debugger、coverage、profiler。

```zig
pub const SourcePosition = struct {
    pc: u32,
    line: u32,
    column: u32,
};

pub const SourcePositionTable = struct {
    entries: []SourcePosition,

    pub fn lookup(self: *const SourcePositionTable, pc: u32) SourcePosition {
        // binary search last entry whose pc <= current pc
    }
};
```

不要依赖 Zig native stack 生成 JS stack trace。JS stack trace 应从 `CallFrame + CodeBlock.source_positions` 生成。

---

## 6. 解释器主循环建议

### 6.1 Frame 结构

```zig
pub const CallFrame = struct {
    prev: ?*CallFrame,

    code: *CodeBlock,
    pc: u32,

    callee: JSValue,
    this_value: JSValue,
    new_target: JSValue,
    lexical_env: *EnvironmentRecord,

    locals_base: usize,
    local_count: u32,

    stack_base: usize,
    stack_top: usize,

    argc: u32,
    flags: FrameFlags,
};
```

VM value stack：

```zig
pub const ValueStack = struct {
    values: []JSValue,
    top: usize,

    pub inline fn push(self: *ValueStack, value: JSValue) void {
        self.values[self.top] = value;
        self.top += 1;
    }

    pub inline fn pop(self: *ValueStack) JSValue {
        self.top -= 1;
        return self.values[self.top];
    }
};
```

### 6.2 Interpreter loop

```zig
pub fn interpret(vm: *VM, frame: *CallFrame) JSResult {
    var pc = frame.pc;
    const code = frame.code;

    while (true) {
        const op: OpCode = @enumFromInt(code.bytecode[pc]);
        pc += 1;

        switch (op) {
            .load_undefined => {
                vm.value_stack.push(JSValue.undefined());
            },

            .load_null => {
                vm.value_stack.push(JSValue.null());
            },

            .load_const => {
                const idx = readU16(code.bytecode, &pc);
                vm.value_stack.push(code.constants[idx]);
            },

            .get_local => {
                const local = readU16(code.bytecode, &pc);
                const value = vm.value_stack.values[frame.locals_base + local];
                vm.value_stack.push(value);
            },

            .set_local => {
                const local = readU16(code.bytecode, &pc);
                const value = vm.value_stack.pop();
                vm.value_stack.values[frame.locals_base + local] = value;
            },

            .get_by_id => {
                const atom_id = readU32(code.bytecode, &pc);
                const metadata_id = readU16(code.bytecode, &pc);

                const base = vm.value_stack.pop();
                const ic = &code.metadata.get_by_id[metadata_id];

                const result = getByIdWithIC(vm, base, atom_id, ic) catch |err| {
                    frame.pc = pc;
                    return vm.throwError(err);
                };

                vm.value_stack.push(result);
            },

            .put_by_id => {
                const atom_id = readU32(code.bytecode, &pc);
                const metadata_id = readU16(code.bytecode, &pc);

                const value = vm.value_stack.pop();
                const base = vm.value_stack.pop();
                const ic = &code.metadata.put_by_id[metadata_id];

                putByIdWithIC(vm, base, atom_id, value, ic) catch |err| {
                    frame.pc = pc;
                    return vm.throwError(err);
                };
            },

            .add => {
                const metadata_id = readU16(code.bytecode, &pc);
                const rhs = vm.value_stack.pop();
                const lhs = vm.value_stack.pop();
                const profile = &code.metadata.arith[metadata_id];

                const result = addWithProfile(vm, lhs, rhs, profile) catch |err| {
                    frame.pc = pc;
                    return vm.throwError(err);
                };

                vm.value_stack.push(result);
            },

            .call => {
                const argc = readU16(code.bytecode, &pc);
                const metadata_id = readU16(code.bytecode, &pc);
                const ic = &code.metadata.call[metadata_id];

                const result = callFromStack(vm, frame, argc, ic) catch |err| {
                    frame.pc = pc;
                    return vm.throwError(err);
                };

                vm.value_stack.push(result);
            },

            .jump => {
                const target = readU32(code.bytecode, &pc);
                pc = target;
            },

            .jump_if_false => {
                const target = readU32(code.bytecode, &pc);
                const cond = vm.value_stack.pop();
                if (!toBoolean(cond)) pc = target;
            },

            .return_ => {
                const result = vm.value_stack.pop();
                frame.pc = pc;
                return .{ .value = result };
            },

            .throw_ => {
                const thrown = vm.value_stack.pop();
                frame.pc = pc;
                return vm.throwValue(thrown);
            },

            .check_interrupt => {
                frame.pc = pc;
                if (vm.interrupt_flags.load(.monotonic) != 0) {
                    vm.handleInterrupt();
                    if (vm.hasException()) return .{ .exception = vm.exception.? };
                }
            },
        }
    }
}
```

---

## 7. Inline Cache 设计

### 7.1 GetByIdIC

`obj.x` 是 JS server 代码最常见 hot path 之一。必须做 IC。

```zig
pub const ICState = enum(u8) {
    uninitialized,
    monomorphic,
    polymorphic,
    megamorphic,
};

pub const GetByIdIC = struct {
    state: ICState,
    key: Atom,

    mono_shape: ?*Shape,
    mono_slot: SlotIndex,
    mono_holder: ?*JSObject,
    mono_proto_epoch: u32,

    poly_entries: [MAX_POLY_IC]GetByIdICEntry,
    poly_len: u8,

    megamorphic_id: u32,
};

pub const GetByIdICEntry = struct {
    shape: *Shape,
    slot: SlotIndex,
    holder: ?*JSObject,
    proto_epoch: u32,
};
```

Fast path：

```zig
pub fn getByIdWithIC(
    vm: *VM,
    base: JSValue,
    key: Atom,
    ic: *GetByIdIC,
) !JSValue {
    if (!base.isObject()) {
        return getByIdSlowAndPatch(vm, base, key, ic);
    }

    const obj = base.asObject();

    switch (ic.state) {
        .monomorphic => {
            if (obj.shape == ic.mono_shape and vm.prototype_epoch == ic.mono_proto_epoch) {
                if (ic.mono_holder) |holder| {
                    return holder.readSlot(ic.mono_slot);
                }
                return obj.readSlot(ic.mono_slot);
            }
        },

        .polymorphic => {
            var i: usize = 0;
            while (i < ic.poly_len) : (i += 1) {
                const entry = ic.poly_entries[i];
                if (obj.shape == entry.shape and vm.prototype_epoch == entry.proto_epoch) {
                    if (entry.holder) |holder| {
                        return holder.readSlot(entry.slot);
                    }
                    return obj.readSlot(entry.slot);
                }
            }
        },

        else => {},
    }

    return getByIdSlowAndPatch(vm, base, key, ic);
}
```

### 7.2 PutByIdIC

```zig
pub const PutByIdIC = struct {
    state: ICState,
    key: Atom,

    mono_shape: ?*Shape,
    mono_new_shape: ?*Shape,
    mono_slot: SlotIndex,
    kind: PutKind,

    poly_entries: [MAX_POLY_IC]PutByIdICEntry,
    poly_len: u8,
};

pub const PutKind = enum(u8) {
    existing_data_property,
    add_data_property_transition,
    setter,
    slow,
};
```

Fast path 要保证：

```text
ordinary object
shape 匹配
不是 proxy
不是 dictionary mode
不是 non-extensible
property writable
没有 accessor setter 语义需要调用
```

写 slot 必须走 GC write barrier：

```zig
pub inline fn writeSlot(vm: *VM, obj: *JSObject, slot: SlotIndex, value: JSValue) void {
    const slot_ptr = obj.slotPtr(slot);
    slot_ptr.* = value;

    if (value.isCell()) {
        vm.gc.writeBarrier(&obj.cell, slot_ptr, value.asCell());
    }
}
```

### 7.3 CallIC

函数调用也需要 IC。

```zig
pub const CallIC = struct {
    state: ICState,

    mono_target: JSValue,
    mono_code: ?*CodeBlock,
    mono_native: ?NativeCallFn,

    argc: u16,
    flags: CallICFlags,
};
```

Fast path：

```text
callee 和 cached target 完全相同
argc 匹配或可快速补 undefined
不是 bound/proxy/exotic call
```

---

## 8. GC 集成

### 8.1 Stack VM 不妨碍精确 GC

Stack VM 的 GC root 来自：

```text
CallFrame metadata
locals
operand stack
this_value
callee
new_target
lexical_env
handle scopes
persistent handles
native async roots
```

P0 可以扫描整个 locals 和 operand stack：

```zig
pub fn traceFrame(vm: *VM, tracer: *Tracer, frame: *CallFrame) void {
    tracer.edgeValue(&frame.callee);
    tracer.edgeValue(&frame.this_value);
    tracer.edgeValue(&frame.new_target);
    tracer.edge(&frame.lexical_env);

    const locals = vm.value_stack.values[
        frame.locals_base .. frame.locals_base + frame.local_count
    ];

    for (locals) |*slot| {
        tracer.edgeValue(slot);
    }

    const operand_stack = vm.value_stack.values[
        frame.stack_base .. frame.stack_top
    ];

    for (operand_stack) |*slot| {
        tracer.edgeValue(slot);
    }
}
```

要求：

```text
所有 local slot 初始化为 undefined。
所有 stack slot 写入前必须是合法 JSValue。
frame.stack_top 必须准确。
异常 unwind 必须正确恢复 stack_top。
```

### 8.2 Stack map

P1/P2 后应生成 stack map：

```zig
pub const StackMap = struct {
    pc: u32,
    live_stack_depth: u32,
    live_locals_bitmap: []const u64,
    stack_slot_bitmap: []const u64,
};

pub const StackMapTable = struct {
    maps: []StackMap,

    pub fn forPc(self: *const StackMapTable, pc: u32) *const StackMap {
        // binary search last safepoint <= pc
    }
};
```

Stack map 用途：

```text
减少 false retention。
支持 moving nursery。
支持 baseline JIT safepoint。
支持 deopt metadata。
支持 debugger 精确显示变量。
```

### 8.3 Safepoint

Stack VM 的 safepoint 位置：

```text
allocation slow path
function call
backward branch / loop backedge
native call return
await / yield
uWS callback return
check_interrupt opcode
```

建议 compiler 在 loop header 插入：

```text
check_interrupt
```

示例：

```js
while (true) {
  work();
}
```

bytecode：

```text
L_loop:
  check_interrupt
  get_global "work"
  call 0, ic0
  pop
  jump L_loop
```

`check_interrupt` 处理：

```text
GC request
termination request
stack overflow
debug break
promise rejection checkpoint
profiling sample
```

---

## 9. Object Model 必须优先于 bytecode 重写

### 9.1 JSObject + Shape

```zig
pub const JSObject = struct {
    cell: Cell,

    shape: *Shape,
    prototype: JSValue,

    inline_slots: [INLINE_SLOT_COUNT]JSValue,
    out_of_line_slots: ?*PropertyStorage,

    elements: Elements,
};

pub const Shape = struct {
    cell: Cell,

    class_id: ClassId,
    prototype: JSValue,
    property_count: u32,
    inline_capacity: u16,
    flags: ShapeFlags,

    descriptors: *PropertyDescriptorTable,
    transitions: ShapeTransitionTable,

    version: u32,
};
```

### 9.2 Shape transition

```zig
pub fn putDataPropertyFast(
    vm: *VM,
    obj: *JSObject,
    key: PropertyKey,
    value: JSValue,
) !void {
    if (obj.shape.lookup(key)) |layout| {
        obj.writeSlot(vm, layout.slot_index, value);
        return;
    }

    if (!obj.isExtensible()) {
        return vm.throwTypeError("object is not extensible");
    }

    const new_shape = try vm.shape_table.transitionAddData(obj.shape, key);
    const slot = new_shape.slotFor(key);

    obj.shape = new_shape;
    vm.gc.writeBarrier(&obj.cell, &obj.shape_slot, &new_shape.cell);

    obj.writeSlot(vm, slot, value);
}
```

### 9.3 Dictionary mode

进入条件：

```text
delete property
属性过多
频繁 Object.defineProperty
属性 attributes 频繁变化
shape transition 链过长
```

```zig
pub const DictionaryStorage = struct {
    table: HashMap(PropertyKey, PropertyEntry),
};

pub const PropertyEntry = struct {
    value: JSValue,
    getter: JSValue,
    setter: JSValue,
    attributes: PropertyAttributes,
};
```

---

## 10. Array / Elements Kind

数组不能只用通用 object property table。

```zig
pub const ElementsKind = enum(u8) {
    empty,
    packed_int32,
    packed_double,
    packed_value,
    holey_int32,
    holey_double,
    holey_value,
    dictionary,
    typed_array,
};

pub const JSArray = struct {
    object: JSObject,
    length: u32,
    length_writable: bool,
    elements_kind: ElementsKind,
    elements: ElementsStorage,
};
```

转换示例：

```text
[1, 2, 3]
  -> packed_int32

[1, 2, 3.5]
  -> packed_double

[1, "x"]
  -> packed_value

delete arr[0]
  -> holey_*

arr[100000] = 1
  -> dictionary or sparse elements
```

对 uWS server，Array 不一定是最大热点，但 Promise reaction queue、headers、route metadata、JSON parse/stringify 都会涉及 Array 快路径。

---

## 11. uWS / Host Integration

### 11.1 每个 uWS loop 一个 VM

推荐模型：

```text
Worker thread 1:
  uWS loop 1
  VM 1
  Heap 1

Worker thread 2:
  uWS loop 2
  VM 2
  Heap 2
```

规则：

```text
JS object 不跨 VM 直接共享。
Persistent handle 只能在所属 VM 释放。
Native resource 可以跨线程，但 JS wrapper 不跨线程。
worker 间通过 structured clone / message passing。
```

### 11.2 uWS callback boundary

```zig
fn onHttpRequest(loop: *UWSLoopBridge, req: *UWSRequest, res: *UWSResponse) void {
    const vm = loop.vm;

    var scope = HandleScope.enter(vm);
    defer scope.exit();

    vm.enterHostCallback();

    const js_req = createRequestWrapper(vm, req);
    const js_res = createResponseWrapper(vm, res);

    const result = vm.callValue(loop.http_handler, JSValue.undefined(), &.{ js_req, js_res });

    if (result.isException()) {
        loop.handleUncaughtException(result.exception());
    }

    vm.leaveHostCallback();

    vm.drainMicrotasksBudgeted();
    vm.gc.runSliceAfterCallback();
    vm.runDeferredNativeCleanupBudgeted();
}
```

### 11.3 Host resource 生命周期

```text
Request wrapper:
  默认 callback-scoped。
  如果异步逃逸，需要 native buffer refcount + external memory accounting。

Response wrapper:
  JS wrapper 可被 GC。
  native response 生命周期由 uWS 控制。
  end/abort 后必须释放 Persistent roots。

WebSocket:
  native connection state 不靠 JS wrapper 存活。
  server behavior callback 通常由 server root 持有。
  send buffer 如果 uWS 不 copy，必须 pin/refcount backing store。
```

---

## 12. Promise / Microtask

Stack bytecode 和 Promise 没冲突。关键是 VM job queue 设计。

```zig
pub const Job = struct {
    kind: JobKind,
    realm: *Realm,
    callback: JobCallback,
    data: JobData,
};

pub const MicrotaskQueue = struct {
    queue: RingBuffer(Job),
};
```

drain 点：

```text
script/module evaluation 完成后
native callback 返回后
uWS callback 返回后
timer/fetch/I/O callback 返回后
Promise resolution 后进入 checkpoint
before event loop idle
```

Budget：

```zig
pub fn drainMicrotasksBudgeted(vm: *VM) void {
    var count: usize = 0;

    while (vm.microtasks.pop()) |job| {
        if (count >= vm.policy.max_microtasks_per_tick) {
            vm.uws_loop.scheduleMicrotaskDrain();
            break;
        }

        vm.runJob(job);
        count += 1;
    }

    vm.gc.clearKeptObjects();
}
```

---

## 13. 什么时候迁移到 accumulator/register bytecode

不要凭感觉迁移。满足以下条件再迁移：

```text
1. profiler 显示 interpreter dispatch 占比非常高。
2. push/pop/dup/swap 占总指令比例过高。
3. 同一 JS 函数 stack bytecode 指令数量明显膨胀。
4. baseline JIT lowering 需要大量 stack simulation。
5. GC liveness / deopt metadata 因 stack effect 变得难维护。
6. IC/profile 和 stack operand 绑定越来越别扭。
7. object model、IC、GC、Promise、module、uWS bridge 已经稳定。
8. 已经计划做 baseline JIT。
```

建议设置 profiler 指标：

```text
bytecode_dispatch_count
opcode_frequency
push_pop_ratio
ic_hit_rate
ic_miss_rate
get_by_id_slow_path_rate
call_slow_path_rate
arith_slow_path_rate
avg_bytecodes_per_function
avg_bytecodes_per_request
interpreter_time_percent
runtime_stub_time_percent
gc_time_percent
uWS_callback_time_percent
```

如果数据表明：

```text
IC hit rate 已经高。
runtime slow path 已经少。
GC 时间可控。
但 interpreter dispatch 占 CPU 大头。
```

这时再迁移 bytecode 才合理。

---

## 14. 推荐迁移路线

### 14.1 Phase A：成熟 stack bytecode interpreter

目标：保持现有 stack VM，补齐生产基础设施。

```text
CodeBlock
metadata side table
stack effect table
bytecode verifier
exception table
source position table
basic stack map
IC metadata
hotness counter
```

这是当前最应该做的阶段。

### 14.2 Phase B：stack + accumulator hybrid

目标：减少 push/pop，不大幅重写 compiler。

新增 opcode：

```text
load_acc_undefined
load_acc_null
load_acc_const
load_acc_local
store_acc_local
get_by_id_acc
put_by_id_acc
add_acc_local
return_acc
```

示例：

```js
return obj.x + obj.y;
```

从 stack bytecode：

```text
get_local obj
get_by_id "x", ic0
get_local obj
get_by_id "y", ic1
add arith0
return
```

演化为 accumulator：

```text
load_local_acc obj
get_by_id_acc "x", ic0
store_acc_local tmp0
load_local_acc obj
get_by_id_acc "y", ic1
add_local_acc tmp0, arith0
return_acc
```

优势：

```text
减少 operand stack 操作。
保留 locals 模型。
不必一次性做完整 register allocator。
IC metadata 可复用。
```

### 14.3 Phase C：register / accumulator bytecode backend

目标：为 baseline JIT 做准备。

做法：

```text
parser / AST / scope analysis 不变。
新增 bytecode backend。
旧 stack backend 暂时保留。
同一测试套件对比两种 backend。
新 backend 逐步接管 hot functions。
```

结构：

```text
AST / HIR
  -> StackBytecodeEmitter
  -> AccumulatorRegisterEmitter
```

不要让两个 backend 共享太多低层 emission 逻辑，但要共享：

```text
scope analysis
constant pool builder
metadata allocator
source position emitter
exception table builder
```

### 14.4 Phase D：baseline JIT

Baseline JIT 依赖：

```text
固定 JSValue ABI
固定 CallFrame layout
CodeBlock metadata stable
IC stable
stack maps stable
slow runtime stubs stable
safepoint protocol stable
```

不要在这些东西不稳定前做 JIT。

---

## 15. Stack bytecode 的 opcode 建议

### 15.1 基础 opcode

```zig
pub const OpCode = enum(u8) {
    nop,

    // constants
    load_undefined,
    load_null,
    load_true,
    load_false,
    load_int,
    load_const,

    // stack
    pop,
    dup,
    swap,

    // locals
    get_local,
    set_local,

    // globals / bindings
    get_global,
    set_global,
    get_name,
    set_name,

    // object/property
    new_object,
    new_array,
    get_by_id,
    put_by_id,
    get_by_value,
    put_by_value,
    define_property,

    // arithmetic
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,

    // compare
    eq,
    strict_eq,
    ne,
    strict_ne,
    lt,
    le,
    gt,
    ge,
    instanceof,
    in_,

    // control flow
    jump,
    jump_if_true,
    jump_if_false,
    jump_if_nullish,

    // call/construct
    call,
    call_this,
    construct,
    return_,
    throw_,

    // environment
    create_lexical_env,
    get_env,
    set_env,
    create_closure,

    // async/generator
    await_,
    yield_,
    resume,

    // module
    get_import,
    set_export,

    // VM
    check_interrupt,
    debug_break,
};
```

### 15.2 编码建议

```text
opcode: u8
small operands: u8/u16
large operands: u32
metadata id: u16 or u32
constant index: u16 initially, expandable
local index: u16
jump target: u32 absolute pc 或 relative i32
```

建议：

```text
P0 用简单定长/半定长编码，方便 debug。
P1 再做 narrow/wide encoding。
不要过早做极致压缩。
```

---

## 16. 编译示例

### 16.1 Property access

JS：

```js
function f(obj) {
  return obj.x;
}
```

Stack bytecode：

```text
function f(obj)
locals:
  0 = obj

0000 get_local   0
0003 get_by_id   "x", ic0
0009 return
```

### 16.2 Binary expression

JS：

```js
function f(a, b) {
  return a + b;
}
```

Stack bytecode：

```text
0000 get_local   0
0003 get_local   1
0006 add         arith0
0009 return
```

### 16.3 Call

JS：

```js
foo(a, b);
```

Stack layout 建议：

```text
push callee
push this_value
push arg0
push arg1
call argc=2, ic0
```

Bytecode：

```text
get_global  "foo"
load_undefined        ; this for bare call
get_local   a
get_local   b
call        argc=2, ic0
pop
```

Call opcode 执行时：

```text
stack before call:
  [..., callee, this, arg0, arg1]

stack after call:
  [..., result]
```

### 16.4 Method call

JS：

```js
obj.foo(a);
```

Bytecode：

```text
get_local       obj
dup                         ; preserve receiver as this
get_by_id       "foo", ic0  ; callee
swap                        ; arrange callee,this,args if needed
get_local       a
call_this       argc=1, ic1
```

可以后续引入 fused opcode 优化：

```text
get_method_by_id "foo", ic0
call_method argc=1, ic1
```

避免过多 `dup/swap`。

---

## 17. Fused opcode 优化

Stack VM 可以通过 fused opcode 显著减少 dispatch。

候选 fused opcode：

```text
get_local_0
get_local_1
set_local_0
load_const_0
load_const_1
get_by_id_direct
put_by_id_direct
get_method_by_id
call0
call1
call2
call_this0
call_this1
return_undefined
return_acc / return_top
jump_if_false_pop
```

不要一开始就加太多 fused opcode。建议根据 profiler 添加。

添加标准：

```text
opcode frequency 高
组合模式稳定
handler 简单
不会显著增加 compiler 复杂度
不会破坏 debugger/source map
```

---

## 18. 性能优化优先级

按收益排序：

```text
1. Shape / HiddenClass object layout
2. get_by_id / put_by_id monomorphic IC
3. call IC
4. array elements kind
5. fast string concat
6. fast path arithmetic int32/double
7. bytecode metadata side table
8. fused opcode
9. accumulator hybrid
10. register bytecode
11. baseline JIT
```

当前不应把 `register bytecode` 放在 `IC` 前面。

原因：

```text
没有 IC 时，obj.x 每次都走完整 property lookup。
这比 stack vs register dispatch 差异大得多。
```

---

## 19. 与 GC 方案的结合

Stack VM 对之前推荐的 GC 方案完全兼容：

```text
copying nursery
+ non-moving old space
+ incremental/concurrent old GC
+ precise handles
+ external memory accounting
```

需要保证：

```text
1. VM value stack 中所有 slot 都是合法 JSValue。
2. frame.stack_top 准确。
3. locals 初始化为 undefined。
4. stack map 能描述 safepoint 处 live stack/local。
5. native call 前后使用 HandleScope。
6. IC metadata 持有的 Shape/Object 需要被 GC trace。
7. CodeBlock metadata 自身必须被 GC 管理或由 CodeBlock trace。
```

Trace CodeBlock metadata：

```zig
fn traceCodeBlock(tracer: *Tracer, code: *CodeBlock) void {
    for (code.constants) |*value| {
        tracer.edgeValue(value);
    }

    for (code.metadata.get_by_id) |*ic| {
        if (ic.mono_shape) |shape| tracer.edge(&shape.cell);
        if (ic.mono_holder) |holder| tracer.edge(&holder.cell);

        for (ic.poly_entries[0..ic.poly_len]) |*entry| {
            tracer.edge(&entry.shape.cell);
            if (entry.holder) |holder| tracer.edge(&holder.cell);
        }
    }

    for (code.metadata.call) |*ic| {
        tracer.edgeValue(&ic.mono_target);
        if (ic.mono_code) |target_code| tracer.edgeCodeBlock(target_code);
    }
}
```

---

## 20. 与 JIT 的关系

保留 stack VM 不会阻止 JIT，但会影响 JIT lowering 复杂度。

### 20.1 Stack bytecode -> baseline JIT

Baseline JIT 可以模拟 operand stack：

```text
bytecode stack slot -> virtual register / machine stack slot
```

示例：

```text
get_local 0
get_by_id "x"
get_local 1
add
return
```

JIT lowering 时维护一个 virtual stack：

```text
get_local 0:
  v0 = load local0
  stack.push(v0)

get_by_id:
  base = stack.pop()
  v1 = emitGetById(base, ic)
  stack.push(v1)

get_local 1:
  v2 = load local1
  stack.push(v2)

add:
  rhs = stack.pop()
  lhs = stack.pop()
  v3 = emitAdd(lhs, rhs, profile)
  stack.push(v3)

return:
  result = stack.pop()
  emitReturn(result)
```

这可行，只是比 register bytecode 多一步 stack simulation。

### 20.2 为什么 JIT 前再迁移更合理

等到 JIT 阶段，你已经有：

```text
真实 opcode frequency
真实 IC hit rate
真实 hot function 数据
真实 GC pause 数据
真实 uWS workload 数据
```

这时可以基于数据决定：

```text
继续 stack bytecode + JIT stack simulation
还是迁移 accumulator/register bytecode
```

---

## 21. 推荐目录结构

```text
src/
├── vm/
│   ├── vm.zig
│   ├── value.zig
│   ├── frame.zig
│   ├── stack.zig
│   ├── handle.zig
│   └── safepoint.zig
├── bytecode/
│   ├── opcode.zig
│   ├── code_block.zig
│   ├── decoder.zig
│   ├── encoder.zig
│   ├── verifier.zig
│   ├── stack_effect.zig
│   ├── metadata.zig
│   ├── exception_table.zig
│   ├── source_position.zig
│   └── stack_map.zig
├── interpreter/
│   ├── dispatch.zig
│   ├── handlers.zig
│   ├── call.zig
│   └── runtime_stubs.zig
├── ic/
│   ├── ic.zig
│   ├── get_by_id.zig
│   ├── put_by_id.zig
│   ├── call.zig
│   └── megamorphic.zig
├── object/
│   ├── object.zig
│   ├── shape.zig
│   ├── property.zig
│   ├── array.zig
│   ├── function.zig
│   ├── proxy.zig
│   └── exotic.zig
├── compiler/
│   ├── ast.zig
│   ├── scope.zig
│   ├── emitter_stack.zig
│   ├── emitter_acc.zig        # 后续添加
│   └── liveness.zig
├── runtime/
│   ├── builtins.zig
│   ├── promise.zig
│   ├── module.zig
│   ├── error.zig
│   ├── string.zig
│   ├── array_buffer.zig
│   └── typed_array.zig
├── host/
│   ├── uws_bridge.zig
│   ├── timers.zig
│   ├── stream.zig
│   └── websocket.zig
└── gc/
    └── ...
```

---

## 22. 测试计划

### 22.1 Bytecode verifier tests

```text
invalid opcode
bad constant index
bad local index
bad metadata index
stack underflow
stack overflow
bad branch target
inconsistent stack depth at merge
bad exception handler range
```

### 22.2 Interpreter tests

```text
literal
local variable
binary expression
property get/set
function call
method call
constructor call
closure
throw/catch/finally
loop/check_interrupt
```

### 22.3 IC tests

```text
monomorphic get_by_id hit
monomorphic miss -> patch
polymorphic transition
megamorphic fallback
prototype property cache
prototype mutation invalidation
put_by_id existing property
put_by_id shape transition
setter slow path
proxy slow path
```

### 22.4 GC stress

```text
GC after every allocation
GC after every bytecode
GC after every property write
GC during native call
GC during exception unwind
GC during Promise reaction
GC after uWS callback
moving nursery stress
```

### 22.5 uWS workload tests

```text
simple HTTP hello world
req.url access hot path
JSON response
Promise response
stream response
WebSocket echo
WebSocket backpressure
request abort
response abort
long-running idle RSS
burst traffic RSS recovery
```

---

## 23. 当前执行清单

如果你现在已经有 stack bytecode VM，下一步建议按这个顺序做：

```text
[ ] 把裸 bytecode 封装成 CodeBlock。
[ ] 增加 MetadataTable。
[ ] 所有 get_by_id / put_by_id / call opcode 带 metadata_id。
[ ] 实现 Shape / HiddenClass。
[ ] 实现 monomorphic get_by_id IC。
[ ] 实现 monomorphic put_by_id IC。
[ ] 实现 call IC。
[ ] 实现 StackEffect table。
[ ] 实现 bytecode verifier。
[ ] 实现 exception table。
[ ] 实现 source position table。
[ ] 实现 frame/stack GC scanning。
[ ] 保证所有 locals 初始化为 undefined。
[ ] 在 loop backedge 插入 check_interrupt。
[ ] 在 uWS callback return 后 drain microtasks + GC slice。
[ ] 记录 opcode frequency 和 IC hit/miss。
[ ] 根据 profiler 决定是否加 fused opcode。
[ ] 再考虑 accumulator hybrid。
```

---

## 24. 最终建议

最终判断：

```text
不要现在从 stack bytecode VM 重写成 register bytecode VM。

你已经有的是 bytecode interpreter。

当前最有价值的工作是把 stack bytecode interpreter 做完整：
  CodeBlock
  metadata side table
  IC
  GC stack map
  exception/source table
  verifier
  profiler
  uWS safepoint

等 object model、IC、GC、Promise、uWS bridge 都稳定，
且 profiler 证明 dispatch/stack traffic 是主要瓶颈，
再迁移到 accumulator/register bytecode。
```

一句话：

> **保留现有 stack bytecode VM。它已经是 bytecode interpreter。短期不要重写 bytecode 架构；先用 metadata side table、Shape/IC、GC stack map、verifier 和 uWS event-loop safepoint 把它做成可生产演进的解释器。后续在 JIT 前再考虑 accumulator/register bytecode。**

---

## 25. 推荐版本路线

```text
VM v0:
  当前 stack bytecode VM 能跑基础语法。

VM v1:
  Stack bytecode + CodeBlock + metadata + verifier + source/exception table。

VM v2:
  Shape object model + get/put/call IC + array elements kind。

VM v3:
  Precise GC integration + stack maps + uWS safepoint + external memory accounting。

VM v4:
  Promise / async / module / host API 完整化。

VM v5:
  Accumulator hybrid opcode，减少 push/pop。

VM v6:
  Register/accumulator bytecode backend，可与 stack backend 并存。

VM v7:
  Baseline JIT，复用 CodeBlock metadata 和 IC。
```
