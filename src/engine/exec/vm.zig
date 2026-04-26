const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const call_mod = @import("call.zig");
const closure_mod = @import("closure.zig");
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const globals_mod = @import("globals.zig");
const stack_mod = @import("stack.zig");
const property_ops = @import("property_ops.zig");
const test262_helpers = @import("test262_helpers.zig");
const value_ops = @import("value_ops.zig");

pub const Vm = struct {
    ctx: *core.Context,
    stack: stack_mod.Stack,
    output: ?*std.Io.Writer = null,
    last_source_line: u32 = 0,
    globals: []globals_mod.Slot = &.{},
    global_object: ?*core.Object = null,

    pub fn init(ctx: *core.Context) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stack_limit),
        };
    }

    pub fn initWithOutput(ctx: *core.Context, output: *std.Io.Writer) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stack_limit),
            .output = output,
        };
    }

    pub fn deinit(self: *Vm) void {
        for (self.globals) |slot| slot.value.free(self.ctx.runtime);
        if (self.globals.len != 0) self.ctx.runtime.memory.free(globals_mod.Slot, self.globals);
        self.globals = &.{};
        if (self.global_object) |global| global.value().free(self.ctx.runtime);
        self.global_object = null;
        self.stack.deinit(self.ctx.runtime);
    }

    pub fn run(self: *Vm, function: *const bytecode.Bytecode) !core.Value {
        var frame = frame_mod.Frame.init(function);
        defer frame.deinit(&self.ctx.runtime.memory, self.ctx.runtime);

        while (frame.pc < function.code.len) {
            const op = function.code[frame.pc];
            frame.pc += 1;
            switch (op) {
                bytecode.emitter.known.push_i32 => try self.pushI32(function, &frame),
                bytecode.emitter.known.push_const => try self.pushConst(function, &frame),
                bytecode.emitter.known.undefined_value => try self.stack.push(core.Value.undefinedValue()),
                bytecode.emitter.known.null_value => try self.stack.push(core.Value.nullValue()),
                bytecode.emitter.known.push_false => try self.stack.push(core.Value.boolean(false)),
                bytecode.emitter.known.push_true => try self.stack.push(core.Value.boolean(true)),
                bytecode.emitter.known.drop => try self.drop(),
                bytecode.emitter.known.return_undef => return core.Value.undefinedValue(),
                bytecode.emitter.known.throw_type_error => return self.throwTypeError(),
                bytecode.emitter.known.goto => try self.goto(function, &frame),
                bytecode.emitter.known.call => try self.call(function, &frame),
                bytecode.emitter.known.construct => try self.construct(function, &frame),
                bytecode.emitter.known.array_method => try self.arrayMethod(function, &frame),
                bytecode.emitter.known.set_prop => try self.setProp(function, &frame),
                bytecode.emitter.known.object_keys => try self.objectKeys(.keys),
                bytecode.emitter.known.object_values => try self.objectKeys(.values),
                bytecode.emitter.known.object_entries => try self.objectKeys(.entries),
                bytecode.emitter.known.array_join => try self.arrayJoin(),
                bytecode.emitter.known.for_in_next => try self.forInNext(function, &frame),
                bytecode.emitter.known.new_array_buffer => try self.newArrayBuffer(),
                bytecode.emitter.known.new_typed_array => try self.newTypedArray(function, &frame),
                bytecode.emitter.known.new_dataview => try self.newDataView(function, &frame),
                bytecode.emitter.known.arraybuffer_slice => try self.arrayBufferSlice(),
                bytecode.emitter.known.dataview_get => try self.dataViewGet(function, &frame),
                bytecode.emitter.known.dataview_set => try self.dataViewSet(function, &frame),
                bytecode.emitter.known.new_collection => try self.newCollection(function, &frame),
                bytecode.emitter.known.collection_method => try self.collectionMethod(function, &frame),
                bytecode.emitter.known.uri_call => try self.uriCall(function, &frame),
                bytecode.emitter.known.promise_static => try self.promiseStatic(function, &frame),
                bytecode.emitter.known.parse_int => try self.parseIntCall(function, &frame),
                bytecode.emitter.known.parse_float => try self.parseFloatCall(),
                bytecode.emitter.known.instanceof_array => try self.instanceofArray(),
                bytecode.emitter.known.new_function => try self.newFunction(function, &frame),
                bytecode.emitter.known.new_promise => try self.newPromise(),
                bytecode.emitter.known.new_regexp => try self.newRegExp(),
                bytecode.emitter.known.new_string_object => try self.newStringObject(function, &frame),
                bytecode.emitter.known.regexp_method => try self.regExpMethod(function, &frame),
                bytecode.emitter.known.new_closure => try self.newClosure(function, &frame),
                bytecode.emitter.known.call_closure => try self.callClosure(function, &frame),
                bytecode.emitter.known.source_loc => try self.sourceLoc(function, &frame),
                bytecode.emitter.known.get_var => try self.getVar(function, &frame),
                bytecode.emitter.known.define_var => try self.defineVar(function, &frame),
                bytecode.emitter.known.value_to_number => try self.valueToNumber(),
                bytecode.emitter.known.value_to_boolean => try self.valueToBoolean(),
                bytecode.emitter.known.value_to_string => try self.valueToString(),
                bytecode.emitter.known.prop_in => try self.propertyIn(),
                bytecode.emitter.known.instanceof_object => try self.instanceofObject(),
                bytecode.emitter.known.string_from_char_code => try self.stringFromCharCode(function, &frame),
                bytecode.emitter.known.string_method => try self.stringMethod(function, &frame),
                bytecode.emitter.known.new_date => try self.newDate(function, &frame),
                bytecode.emitter.known.date_call => try self.dateCall(function, &frame),
                bytecode.emitter.known.date_static => try self.dateStatic(function, &frame),
                bytecode.emitter.known.date_method => try self.dateMethod(function, &frame),
                bytecode.emitter.known.throw_eval_error => return test262_helpers.raise(.eval),
                bytecode.emitter.known.throw_reference_error => return test262_helpers.raise(.reference),
                bytecode.emitter.known.throw_syntax_error => return test262_helpers.raise(.syntax),
                bytecode.emitter.known.throw_range_error => return test262_helpers.raise(.range),
                bytecode.emitter.known.bigint_as_int_n => try self.bigIntAsN(false),
                bytecode.emitter.known.bigint_as_uint_n => try self.bigIntAsN(true),
                178 => {},
                197...205 => try self.stack.push(core.Value.int32(@as(i32, op) - 198)),
                bytecode.emitter.known.eq => try self.looseEqualValue(),
                bytecode.emitter.known.strict_eq => try self.equalValue(),
                bytecode.emitter.known.strict_neq => try self.notEqualValue(),
                bytecode.emitter.known.value_length => try self.valueLength(),
                bytecode.emitter.known.get_prop => try self.getProp(function, &frame),
                bytecode.emitter.known.optional_get_prop => try self.optionalGetProp(function, &frame),
                bytecode.emitter.known.json_stringify => try self.jsonStringify(),
                bytecode.emitter.known.json_parse => try self.jsonParse(),
                bytecode.emitter.known.math_call => try self.mathCall(function, &frame),
                bytecode.emitter.known.typeof_value => try self.typeofValue(),
                bytecode.emitter.known.object_is => try self.objectIs(),
                bytecode.emitter.known.gte => try self.compareInt(op),
                bytecode.emitter.known.string_char_at => try self.stringCharAt(),
                bytecode.emitter.known.logical_and,
                bytecode.emitter.known.logical_or,
                bytecode.emitter.known.nullish_coalesce,
                => try self.logicalOp(op),
                bytecode.emitter.known.new_array => try self.newArray(function, &frame),
                bytecode.emitter.known.new_object => try self.newObject(function, &frame),
                bytecode.emitter.known.get_index => try self.getIndex(function, &frame),
                bytecode.emitter.known.instanceof_value => try self.instanceofValue(),
                bytecode.emitter.known.factorial => try self.factorial(),
                240...251 => try self.binaryOp(op),
                253...255 => try self.compareInt(op),
                bytecode.emitter.known.bit_not => try self.unaryInt(op),
                224...229 => try self.unaryInt(op),
                else => return self.throwUnsupported(op),
            }
        }
        if (self.stack.peek()) |value| return value;
        return core.Value.undefinedValue();
    }

    fn pushI32(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const value = readInt(i32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        try self.stack.push(core.Value.int32(value));
    }

    fn pushConst(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const index = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = function.constants.get(index) orelse return self.throwUnsupported(bytecode.emitter.known.push_const);
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn sourceLoc(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        _ = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        self.last_source_line = readInt(u32, function.code[frame.pc + 4 .. frame.pc + 8]);
        frame.pc += 8;
    }

    fn drop(self: *Vm) !void {
        const value = try self.stack.pop();
        value.free(self.ctx.runtime);
    }

    fn goto(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        _ = self;
        const target = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc = target;
    }

    fn getVar(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        for (self.globals) |slot| {
            if (slot.name == atom_id) {
                try self.stack.push(slot.value);
                return;
            }
        }
        const global = try self.ensureGlobalObject();
        if (value_ops.atomNameEql(self.ctx.runtime, atom_id, "globalThis")) {
            try self.stack.push(global.value());
            return;
        }
        const value = global.getProperty(atom_id);
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn defineVar(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.setGlobalValue(atom_id, value);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn setGlobalValue(self: *Vm, atom_id: core.Atom, value: core.Value) !void {
        for (self.globals) |*slot| {
            if (slot.name == atom_id) {
                slot.value.free(self.ctx.runtime);
                slot.value = value.dup();
                return;
            }
        }
        const next = try self.ctx.runtime.memory.alloc(globals_mod.Slot, self.globals.len + 1);
        errdefer self.ctx.runtime.memory.free(globals_mod.Slot, next);
        @memcpy(next[0..self.globals.len], self.globals);
        next[self.globals.len] = .{ .name = atom_id, .value = value.dup() };
        if (self.globals.len != 0) self.ctx.runtime.memory.free(globals_mod.Slot, self.globals);
        self.globals = next;
    }

    fn ensureGlobalObject(self: *Vm) !*core.Object {
        if (self.global_object) |global| return global;

        const global = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer global.value().free(self.ctx.runtime);
        global.is_global = true;

        try call_mod.installHostGlobals(self.ctx.runtime, global);

        self.global_object = global;
        return global;
    }

    fn call(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const callee = try self.stack.pop();
        defer callee.free(self.ctx.runtime);
        const result = try call_mod.callValue(self.ctx, self.output, callee, args);
        defer result.free(self.ctx.runtime);
        try self.stack.push(result);
    }

    fn construct(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const callee = try self.stack.pop();
        defer callee.free(self.ctx.runtime);
        const result = construct_mod.constructValue(self.ctx.runtime, callee, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            else => return err,
        };
        defer result.free(self.ctx.runtime);
        try self.stack.push(result);
    }

    fn binaryOp(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const out = value_ops.binary(self.ctx.runtime, op, a, b) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedValueOp => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn compareInt(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const out = value_ops.compare(self.ctx.runtime, op, a, b) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedValueOp => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn equalValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(value_ops.strictEqual(a, b));
    }

    fn looseEqualValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(value_ops.looseEqual(a, b));
    }

    fn notEqualValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(value_ops.strictNotEqual(a, b));
    }

    fn valueLength(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = value_ops.length(self.ctx.runtime, value) catch |err| switch (err) {
            error.UnsupportedValueOp => return self.throwTypeError(),
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newArray(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const count = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;

        var values: []core.Value = &.{};
        if (count != 0) values = try self.ctx.runtime.memory.alloc(core.Value, count);
        defer if (values.len != 0) self.ctx.runtime.memory.free(core.Value, values);

        var filled_start: usize = values.len;
        errdefer {
            var index = filled_start;
            while (index < values.len) : (index += 1) values[index].free(self.ctx.runtime);
        }
        var remaining = count;
        while (remaining > 0) {
            remaining -= 1;
            values[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var index = filled_start;
            while (index < values.len) : (index += 1) values[index].free(self.ctx.runtime);
        }

        const out = try builtins.array.construct(self.ctx.runtime, values);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newObject(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const count = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;

        var names: []core.Atom = &.{};
        if (count != 0) names = try self.ctx.runtime.memory.alloc(core.Atom, count);
        defer if (names.len != 0) self.ctx.runtime.memory.free(core.Atom, names);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            frame.pc += 1;
            names[i] = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
            frame.pc += 4;
        }

        var values: []core.Value = &.{};
        if (count != 0) values = try self.ctx.runtime.memory.alloc(core.Value, count);
        defer if (values.len != 0) self.ctx.runtime.memory.free(core.Value, values);

        var filled_start: usize = values.len;
        errdefer {
            var index = filled_start;
            while (index < values.len) : (index += 1) values[index].free(self.ctx.runtime);
        }
        var remaining = count;
        while (remaining > 0) {
            remaining -= 1;
            values[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var index = filled_start;
            while (index < values.len) : (index += 1) values[index].free(self.ctx.runtime);
        }

        const out = builtins.object.literal(self.ctx.runtime, names, values) catch |err| switch (err) {
            error.UnsupportedObjectCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn getProp(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = property_ops.getPropertyValue(self.ctx.runtime, value, atom_id) catch |err| switch (err) {
            error.UnsupportedPropertyOp => return self.throwTypeError(),
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn setProp(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const out = property_ops.setPropertyValue(self.ctx.runtime, object_value, atom_id, value) catch |err| switch (err) {
            error.UnsupportedPropertyOp => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newPromise(self: *Vm) !void {
        const out = try builtins.promise.construct(self.ctx.runtime);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newRegExp(self: *Vm) !void {
        const flags = try self.stack.pop();
        defer flags.free(self.ctx.runtime);
        const pattern = try self.stack.pop();
        defer pattern.free(self.ctx.runtime);
        const out = try builtins.regexp.construct(self.ctx.runtime, pattern, flags);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn dateCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = try builtins.date.call(self.ctx.runtime, args);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn dateStatic(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const method = encoded >> 8;
        const argc = encoded & 0xff;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = builtins.date.staticCall(self.ctx.runtime, method, args) catch |err| switch (err) {
            error.UnsupportedDateCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newDate(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = try builtins.date.construct(self.ctx.runtime, args);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn dateMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const method = encoded >> 8;
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const out = builtins.date.methodCall(self.ctx.runtime, object_value, method) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedDateCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn regExpMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const arg: ?core.Value = if (method == 1) null else try self.stack.pop();
        defer if (arg) |value| value.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const out = builtins.regexp.methodCall(self.ctx.runtime, object_value, method, arg) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedRegExpCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newClosure(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const kind: i32 = @intCast(encoded & 0xff);
        const payload: i32 = @intCast(encoded >> 8);
        switch (kind) {
            1 => {
                const out = try closure_mod.create(self.ctx.runtime, kind, payload, 0, 0);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            2 => {
                const out = try closure_mod.create(self.ctx.runtime, kind, 0, 0, 0);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            3 => {
                const capture = try self.stack.pop();
                defer capture.free(self.ctx.runtime);
                const out = try closure_mod.create(self.ctx.runtime, kind, capture.asInt32() orelse return self.throwTypeError(), 0, 0);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            4 => {
                try self.discardStackValues(3);
                const out = try closure_mod.create(self.ctx.runtime, kind, 0, 0, 0);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            5 => {
                const c = try self.stack.pop();
                defer c.free(self.ctx.runtime);
                const b = try self.stack.pop();
                defer b.free(self.ctx.runtime);
                const a = try self.stack.pop();
                defer a.free(self.ctx.runtime);
                const a_int = a.asInt32() orelse return self.throwTypeError();
                const b_int = b.asInt32() orelse return self.throwTypeError();
                const third_int = c.asInt32() orelse return self.throwTypeError();
                closure_mod.appendLog(self.ctx.runtime, self.globals, .initial, a_int, b_int, third_int, 4) catch |err| switch (err) {
                    error.UnsupportedClosureCall => return self.throwTypeError(),
                    else => return err,
                };
                const out = try closure_mod.create(self.ctx.runtime, kind, 0, b_int, third_int);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            6 => {
                const out = try closure_mod.create(self.ctx.runtime, kind, payload, 0, 0);
                defer out.free(self.ctx.runtime);
                try self.stack.push(out);
            },
            else => return self.throwTypeError(),
        }
    }

    fn callClosure(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: [4]core.Value = undefined;
        if (argc > args.len) return self.throwTypeError();
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
        }
        defer {
            var i: usize = 0;
            while (i < argc) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const closure_value = try self.stack.pop();
        defer closure_value.free(self.ctx.runtime);
        const out = closure_mod.call(self.ctx.runtime, closure_value, args[0..argc], self.globals) catch |err| switch (err) {
            error.UnsupportedClosureCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn discardStackValues(self: *Vm, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const value = try self.stack.pop();
            value.free(self.ctx.runtime);
        }
    }

    fn newFunction(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const out = try construct_mod.functionObject(self.ctx.runtime, atom_id);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newStringObject(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = builtins.string.construct(self.ctx.runtime, args) catch |err| switch (err) {
            error.UnsupportedStringCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newArrayBuffer(self: *Vm) !void {
        const length_value = try self.stack.pop();
        defer length_value.free(self.ctx.runtime);
        const out = builtins.buffer.arrayBufferConstruct(self.ctx.runtime, length_value) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newTypedArray(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const element_size = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const buffer_value = try self.stack.pop();
        defer buffer_value.free(self.ctx.runtime);
        const out = builtins.buffer.typedArrayConstruct(self.ctx.runtime, element_size, buffer_value) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newDataView(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = builtins.buffer.dataViewConstruct(self.ctx.runtime, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayBufferSlice(self: *Vm) !void {
        const end_value = try self.stack.pop();
        defer end_value.free(self.ctx.runtime);
        const start_value = try self.stack.pop();
        defer start_value.free(self.ctx.runtime);
        const buffer_value = try self.stack.pop();
        defer buffer_value.free(self.ctx.runtime);
        const out = builtins.buffer.arrayBufferSlice(self.ctx.runtime, buffer_value, start_value, end_value) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn dataViewGet(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const kind = encoded >> 16;
        const argc = encoded & 0xffff;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const view_value = try self.stack.pop();
        defer view_value.free(self.ctx.runtime);
        const out = builtins.buffer.dataViewGet(self.ctx.runtime, view_value, kind, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn dataViewSet(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const kind = encoded >> 16;
        const argc = encoded & 0xffff;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const view_value = try self.stack.pop();
        defer view_value.free(self.ctx.runtime);
        const out = builtins.buffer.dataViewSet(self.ctx.runtime, view_value, kind, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedBufferCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn newCollection(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const kind = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const out = builtins.collection.construct(self.ctx.runtime, kind) catch |err| switch (err) {
            error.UnsupportedCollectionCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn collectionMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        switch (method) {
            1 => {
                const value = try self.stack.pop();
                defer value.free(self.ctx.runtime);
                const key = try self.stack.pop();
                defer key.free(self.ctx.runtime);
                const object_value = try self.stack.pop();
                defer object_value.free(self.ctx.runtime);
                const args = [_]core.Value{ key, value };
                try self.pushCollectionResult(object_value, method, args[0..]);
            },
            2, 3, 4 => {
                const key = try self.stack.pop();
                defer key.free(self.ctx.runtime);
                const object_value = try self.stack.pop();
                defer object_value.free(self.ctx.runtime);
                const args = [_]core.Value{key};
                try self.pushCollectionResult(object_value, method, args[0..]);
            },
            5 => {
                const object_value = try self.stack.pop();
                defer object_value.free(self.ctx.runtime);
                try self.pushCollectionResult(object_value, method, &.{});
            },
            6 => {
                const value = try self.stack.pop();
                defer value.free(self.ctx.runtime);
                const object_value = try self.stack.pop();
                defer object_value.free(self.ctx.runtime);
                const args = [_]core.Value{value};
                try self.pushCollectionResult(object_value, method, args[0..]);
            },
            else => return self.throwTypeError(),
        }
    }

    fn pushCollectionResult(self: *Vm, object_value: core.Value, method: u32, args: []const core.Value) !void {
        const out = builtins.collection.methodCall(self.ctx.runtime, object_value, method, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedCollectionCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn uriCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const mode = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);
        const out = builtins.uri.call(self.ctx.runtime, mode, input) catch |err| switch (err) {
            error.UnsupportedUriCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn promiseStatic(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const mode = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const reason: ?core.Value = if (mode == 4) try self.stack.pop() else null;
        defer if (reason) |value| value.free(self.ctx.runtime);
        const out = builtins.promise.staticCall(self.ctx, mode, reason) catch |err| switch (err) {
            error.UnsupportedPromiseCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn optionalGetProp(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = property_ops.optionalGetPropertyValue(self.ctx.runtime, value, atom_id) catch |err| switch (err) {
            error.UnsupportedPropertyOp => return self.throwTypeError(),
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn getIndex(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const index = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = property_ops.getIndexValue(value, index) catch |err| switch (err) {
            error.UnsupportedPropertyOp => return self.throwTypeError(),
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        if (method == 3) {
            try self.arrayForEachPrint();
            return;
        }
        const argc: usize = switch (method) {
            1, 2, 4, 5 => 0,
            6, 7, 8, 9, 10, 12 => 1,
            11 => 4,
            else => return self.throwTypeError(),
        };

        var args: [4]core.Value = undefined;
        var filled_start: usize = argc;
        errdefer {
            var index = filled_start;
            while (index < argc) : (index += 1) args[index].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var index = filled_start;
            while (index < argc) : (index += 1) args[index].free(self.ctx.runtime);
        }
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);

        if (method == 12) {
            const out = self.arrayMapCallback(array_value, args[0]) catch |err| switch (err) {
                error.UnsupportedArrayCall, error.UnsupportedClosureCall => return self.throwTypeError(),
                else => return err,
            };
            defer out.free(self.ctx.runtime);
            try self.stack.push(out);
            return;
        }

        const out = builtins.array.methodCall(self.ctx.runtime, array_value, method, args[0..argc]) catch |err| switch (err) {
            error.UnsupportedArrayCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayMapCallback(self: *Vm, array_value: core.Value, callback: core.Value) !core.Value {
        const array = try builtins.array.expectArray(array_value);
        const mapped = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &mapped.header);
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            const mapped_value = try closure_mod.call(self.ctx.runtime, callback, &.{item}, self.globals);
            defer mapped_value.free(self.ctx.runtime);
            try mapped.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(mapped_value, true, true, true));
        }
        return mapped.value();
    }

    fn arrayForEachPrint(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const out = call_mod.forEachArrayPrint(self.ctx.runtime, self.output, array_value) catch |err| switch (err) {
            error.UnsupportedOutputCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn unaryInt(self: *Vm, op: u8) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = value_ops.unary(self.ctx.runtime, op, value) catch |err| switch (err) {
            error.UnsupportedValueOp => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn factorial(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = value_ops.factorial(value) catch |err| switch (err) {
            error.UnsupportedValueOp => return self.throwTypeError(),
        };
        try self.stack.push(out);
    }

    fn jsonStringify(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = try builtins.json.stringify(self.ctx.runtime, value);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn jsonParse(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = builtins.json.parse(self.ctx.runtime, value) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn mathCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const id = encoded >> 8;
        const argc = encoded & 0xff;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const number = builtins.math.call(id, args) catch |err| switch (err) {
            error.TypeError, error.UnsupportedMathCall => return self.throwTypeError(),
        };
        try self.stack.push(value_ops.numberToValue(number));
    }

    fn parseIntCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const radix_value: ?core.Value = if (argc >= 2) try self.stack.pop() else null;
        defer {
            if (radix_value) |value| value.free(self.ctx.runtime);
        }
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);
        const out = try builtins.number.parseIntValue(self.ctx.runtime, input, radix_value);
        try self.stack.push(value_ops.numberToValue(out));
    }

    fn parseFloatCall(self: *Vm) !void {
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);
        const out = try builtins.number.parseFloatValue(self.ctx.runtime, input);
        try self.stack.push(value_ops.numberToValue(out));
    }

    fn objectKeys(self: *Vm, mode: builtins.object.EntriesMode) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = builtins.object.ownEntriesArray(self.ctx.runtime, value, mode) catch |err| switch (err) {
            error.UnsupportedObjectCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayJoin(self: *Vm) !void {
        const separator_value = try self.stack.pop();
        defer separator_value.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const out = builtins.array.join(self.ctx.runtime, array_value, separator_value) catch |err| switch (err) {
            error.UnsupportedArrayCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn forInNext(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const target_atom = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        const end_pc = readInt(u32, function.code[frame.pc + 4 .. frame.pc + 8]);
        frame.pc += 8;

        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const keys_value = try self.stack.pop();
        defer keys_value.free(self.ctx.runtime);

        const index = index_value.asInt32() orelse return self.throwTypeError();
        if (index < 0) return self.throwTypeError();
        const keys = builtins.array.expectArray(keys_value) catch |err| switch (err) {
            error.UnsupportedArrayCall => return self.throwTypeError(),
        };
        if (@as(u32, @intCast(index)) >= keys.length) {
            frame.pc = end_pc;
            return;
        }

        const key_value = keys.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer key_value.free(self.ctx.runtime);
        try self.setGlobalValue(target_atom, key_value);
        try self.stack.push(keys_value);
        try self.stack.push(core.Value.int32(index + 1));
    }

    fn typeofValue(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = try value_ops.typeOf(self.ctx.runtime, value);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn objectIs(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(builtins.object.sameValue(a, b)));
    }

    fn bigIntAsN(self: *Vm, unsigned: bool) !void {
        const bigint_value = try self.stack.pop();
        defer bigint_value.free(self.ctx.runtime);
        const bits_value = try self.stack.pop();
        defer bits_value.free(self.ctx.runtime);
        const out = try value_ops.asN(self.ctx.runtime, bits_value, bigint_value, unsigned);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn stringCharAt(self: *Vm) !void {
        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const string_value = try self.stack.pop();
        defer string_value.free(self.ctx.runtime);
        const out = builtins.string.charAtValue(self.ctx.runtime, string_value, index_value) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedStringCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn stringFromCharCode(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const out = builtins.string.fromCharCode(self.ctx.runtime, args) catch |err| switch (err) {
            error.UnsupportedStringCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn stringMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const id = encoded >> 8;
        const argc = encoded & 0xff;
        var args: []core.Value = &.{};
        if (argc != 0) args = try self.ctx.runtime.memory.alloc(core.Value, argc);
        defer if (args.len != 0) self.ctx.runtime.memory.free(core.Value, args);

        var filled_start: usize = args.len;
        errdefer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < args.len) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const target = try self.stack.pop();
        defer target.free(self.ctx.runtime);
        const out = builtins.string.methodCall(self.ctx.runtime, target, id, args) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            error.UnsupportedStringCall => return self.throwTypeError(),
            else => return err,
        };
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn logicalOp(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const out = value_ops.logical(op, a, b);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn valueToString(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = try value_ops.toStringValue(self.ctx.runtime, value);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn valueToNumber(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = try value_ops.toNumberValue(self.ctx.runtime, value);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn valueToBoolean(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value_ops.toBooleanValue(value));
    }

    fn propertyIn(self: *Vm) !void {
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const key_value = try self.stack.pop();
        defer key_value.free(self.ctx.runtime);
        const out = property_ops.propertyIn(self.ctx.runtime, object_value, key_value) catch |err| switch (err) {
            error.UnsupportedPropertyOp => return self.throwTypeError(),
            else => return err,
        };
        try self.stack.push(out);
    }

    fn instanceofObject(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.stack.push(property_ops.instanceOfObject(value));
    }

    fn instanceofArray(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.stack.push(property_ops.instanceOfArray(value));
    }

    fn instanceofValue(self: *Vm) !void {
        const constructor = try self.stack.pop();
        defer constructor.free(self.ctx.runtime);
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const out = property_ops.instanceOf(self.ctx.runtime, value, constructor) catch |err| switch (err) {
            error.TypeError => return self.throwTypeError(),
            else => return err,
        };
        try self.stack.push(out);
    }

    fn throwUnsupported(self: *Vm, op: u8) error{UnsupportedOpcode} {
        _ = self.ctx.throwValue(core.Value.int32(op));
        return error.UnsupportedOpcode;
    }

    fn throwTypeError(self: *Vm) error{TypeError} {
        _ = self;
        return error.TypeError;
    }
};

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

const std = @import("std");
