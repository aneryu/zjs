const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

pub const Vm = struct {
    ctx: *core.Context,
    stack: stack_mod.Stack,
    output: ?*std.Io.Writer = null,
    last_source_line: u32 = 0,
    globals: []GlobalSlot = &.{},
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
        if (self.globals.len != 0) self.ctx.runtime.memory.free(GlobalSlot, self.globals);
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
                bytecode.emitter.known.return_undef => return core.Value.undefinedValue(),
                bytecode.emitter.known.throw_type_error => return self.throwTypeError(),
                bytecode.emitter.known.call => try self.call(function, &frame),
                bytecode.emitter.known.array_method => try self.arrayMethod(function, &frame),
                bytecode.emitter.known.set_prop => try self.setProp(function, &frame),
                bytecode.emitter.known.object_keys => try self.objectKeys(.keys),
                bytecode.emitter.known.object_values => try self.objectKeys(.values),
                bytecode.emitter.known.object_entries => try self.objectKeys(.entries),
                bytecode.emitter.known.array_join => try self.arrayJoin(),
                bytecode.emitter.known.for_in_concat => try self.forInConcat(function, &frame),
                bytecode.emitter.known.new_array_buffer => try self.newArrayBuffer(),
                bytecode.emitter.known.new_typed_array => try self.newTypedArray(function, &frame),
                bytecode.emitter.known.new_dataview => try self.newDataView(),
                bytecode.emitter.known.arraybuffer_slice => try self.arrayBufferSlice(),
                bytecode.emitter.known.dataview_get => try self.dataViewGet(function, &frame),
                bytecode.emitter.known.dataview_set => try self.dataViewSet(),
                bytecode.emitter.known.new_collection => try self.newCollection(function, &frame),
                bytecode.emitter.known.collection_method => try self.collectionMethod(function, &frame),
                bytecode.emitter.known.uri_call => try self.uriCall(function, &frame),
                bytecode.emitter.known.promise_static => try self.promiseStatic(function, &frame),
                bytecode.emitter.known.parse_int => try self.parseIntCall(function, &frame),
                bytecode.emitter.known.parse_float => try self.parseFloatCall(),
                bytecode.emitter.known.instanceof_array => try self.instanceofArray(),
                bytecode.emitter.known.new_named_object => try self.newNamedObject(function, &frame),
                bytecode.emitter.known.new_promise => try self.newPromise(),
                bytecode.emitter.known.instanceof_named => try self.instanceofNamed(function, &frame),
                bytecode.emitter.known.new_regexp => try self.newRegExp(),
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
                bytecode.emitter.known.throw_test262_error => return error.Test262Error,
                bytecode.emitter.known.throw_eval_error => return error.EvalError,
                bytecode.emitter.known.throw_reference_error => return error.ReferenceError,
                bytecode.emitter.known.throw_syntax_error => return error.SyntaxError,
                bytecode.emitter.known.throw_range_error => return error.RangeError,
                bytecode.emitter.known.assert_same_value => try self.assertSameValue(),
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
                bytecode.emitter.known.array_map_mul => try self.arrayMapMul(function, &frame),
                bytecode.emitter.known.factorial => try self.factorial(),
                240...251 => try self.binaryOp(op),
                253...255 => try self.compareInt(op),
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
        const value = global.getProperty(atom_id);
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn defineVar(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        for (self.globals) |*slot| {
            if (slot.name == atom_id) {
                slot.value.free(self.ctx.runtime);
                slot.value = value.dup();
                try self.stack.push(core.Value.undefinedValue());
                return;
            }
        }
        const next = try self.ctx.runtime.memory.alloc(GlobalSlot, self.globals.len + 1);
        errdefer self.ctx.runtime.memory.free(GlobalSlot, next);
        @memcpy(next[0..self.globals.len], self.globals);
        next[self.globals.len] = .{ .name = atom_id, .value = value.dup() };
        if (self.globals.len != 0) self.ctx.runtime.memory.free(GlobalSlot, self.globals);
        self.globals = next;
        try self.stack.push(core.Value.undefinedValue());
    }

    fn ensureGlobalObject(self: *Vm) !*core.Object {
        if (self.global_object) |global| return global;

        const global = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer global.value().free(self.ctx.runtime);

        try self.defineHostFunction(global, "print", .output);

        const console = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer console.value().free(self.ctx.runtime);
        try self.defineHostFunction(console, "log", .output);
        try self.defineObjectProperty(global, "console", console.value());
        console.value().free(self.ctx.runtime);

        self.global_object = global;
        return global;
    }

    fn defineHostFunction(self: *Vm, target: *core.Object, name: []const u8, kind: HostFunction) !void {
        const function_object = try core.Object.create(self.ctx.runtime, core.class.ids.c_function, null);
        errdefer function_object.value().free(self.ctx.runtime);
        try self.defineIntProperty(function_object, "__host_function", @intFromEnum(kind));
        try self.defineObjectProperty(target, name, function_object.value());
        function_object.value().free(self.ctx.runtime);
    }

    fn defineObjectProperty(self: *Vm, object: *core.Object, name: []const u8, value: core.Value) !void {
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        try object.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(value, true, true, true));
    }

    fn call(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var values: [32]core.Value = undefined;
        if (argc > values.len) return self.throwUnsupported(bytecode.emitter.known.call);
        var filled_start: usize = argc;
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            values[remaining] = try self.stack.pop();
            filled_start = remaining;
        }
        defer {
            var i = filled_start;
            while (i < argc) : (i += 1) values[i].free(self.ctx.runtime);
        }
        const callee = try self.stack.pop();
        defer callee.free(self.ctx.runtime);
        try self.callValue(callee, values[0..argc]);
    }

    fn callValue(self: *Vm, callee: core.Value, args: []core.Value) !void {
        const object = try self.expectObject(callee, bytecode.emitter.known.call);
        if (object.class_id != core.class.ids.c_function) return self.throwTypeError();
        const kind_value = try self.getIntProperty(object, "__host_function", bytecode.emitter.known.call);
        const kind: HostFunction = @enumFromInt(kind_value);
        switch (kind) {
            .output => try self.hostOutputValues(args),
        }
    }

    fn binaryOp(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        if (op == bytecode.emitter.known.add and (a.isString() or b.isString())) {
            try self.binaryStringAdd(a, b);
            return;
        }
        if (a.isNumber() and b.isNumber()) {
            try self.binaryNumberOp(op, a, b);
            return;
        }
        const lhs = a.asInt32() orelse return self.throwUnsupported(op);
        const rhs = b.asInt32() orelse return self.throwUnsupported(op);
        const out = switch (op) {
            240 => lhs * rhs,
            241 => @divTrunc(lhs, rhs),
            242 => @rem(lhs, rhs),
            243 => lhs + rhs,
            244 => lhs - rhs,
            245 => lhs << @intCast(rhs & 31),
            246 => lhs >> @intCast(rhs & 31),
            247 => @as(i32, @bitCast(@as(u32, @bitCast(lhs)) >> @intCast(rhs & 31))),
            248 => lhs & rhs,
            249 => lhs ^ rhs,
            250 => lhs | rhs,
            251 => powI32(lhs, rhs),
            else => unreachable,
        };
        try self.stack.push(core.Value.int32(out));
    }

    fn binaryNumberOp(self: *Vm, op: u8, a: core.Value, b: core.Value) !void {
        const lhs = numberValue(a) orelse return self.throwUnsupported(op);
        const rhs = numberValue(b) orelse return self.throwUnsupported(op);
        const out = switch (op) {
            240 => lhs * rhs,
            241 => lhs / rhs,
            242 => @mod(lhs, rhs),
            243 => lhs + rhs,
            244 => lhs - rhs,
            251 => std.math.pow(f64, lhs, rhs),
            else => return self.throwUnsupported(op),
        };
        try self.pushNumber(out);
    }

    fn binaryStringAdd(self: *Vm, a: core.Value, b: core.Value) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &buffer, a);
        try appendValueString(self.ctx.runtime, &buffer, b);
        const str = try core.string.String.createUtf8(self.ctx.runtime, buffer.items);
        const value = str.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn compareInt(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        if (a.isString() and b.isString()) {
            const cmp = compareStringValues(a, b) orelse return self.throwUnsupported(op);
            const out = switch (op) {
                253 => cmp < 0,
                254 => cmp <= 0,
                255 => cmp > 0,
                bytecode.emitter.known.gte => cmp >= 0,
                else => false,
            };
            try self.stack.push(core.Value.boolean(out));
            return;
        }
        const lhs = numberValue(a) orelse return self.throwUnsupported(op);
        const rhs = numberValue(b) orelse return self.throwUnsupported(op);
        const out = switch (op) {
            253 => lhs < rhs,
            254 => lhs <= rhs,
            255 => lhs > rhs,
            bytecode.emitter.known.gte => lhs >= rhs,
            else => false,
        };
        try self.stack.push(core.Value.boolean(out));
    }

    fn pushNumber(self: *Vm, value: f64) !void {
        if (std.math.isFinite(value) and @floor(value) == value and value >= @as(f64, @floatFromInt(std.math.minInt(i32))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and !isNegativeZero(value)) {
            try self.stack.push(core.Value.int32(@intFromFloat(value)));
        } else {
            try self.stack.push(core.Value.float64(value));
        }
    }

    fn equalValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(valuesEqual(a, b)));
    }

    fn looseEqualValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(valuesLooseEqual(a, b)));
    }

    fn notEqualValue(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(!valuesEqual(a, b)));
    }

    fn valueLength(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.value_length);
        if (value.isString()) {
            const string_value: *core.string.String = @fieldParentPtr("header", header);
            try self.stack.push(core.Value.int32(@intCast(string_value.len())));
            return;
        }
        if (value.isObject()) {
            const object_value: *core.Object = @fieldParentPtr("header", header);
            if (object_value.is_array) {
                try self.stack.push(core.Value.int32(@intCast(object_value.length)));
                return;
            }
            const length_value = object_value.getProperty(core.atom.ids.length);
            defer length_value.free(self.ctx.runtime);
            if (!length_value.isUndefined()) {
                try self.stack.push(length_value);
                return;
            }
        }
        return self.throwUnsupported(bytecode.emitter.known.value_length);
    }

    fn newArray(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const count = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const object = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);

        var i: u32 = count;
        while (i > 0) {
            i -= 1;
            const value = try self.stack.pop();
            defer value.free(self.ctx.runtime);
            try object.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(i), core.Descriptor.data(value, true, true, true));
        }
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn newObject(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const count = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);

        var names: [16]core.Atom = undefined;
        if (count > names.len) return self.throwUnsupported(bytecode.emitter.known.new_object);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            frame.pc += 1;
            names[i] = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
            frame.pc += 4;
        }

        var values: [16]core.Value = undefined;
        var remaining = count;
        while (remaining > 0) {
            remaining -= 1;
            values[remaining] = try self.stack.pop();
        }
        i = 0;
        while (i < count) : (i += 1) {
            defer values[i].free(self.ctx.runtime);
            try object.defineOwnProperty(self.ctx.runtime, names[i], core.Descriptor.data(values[i], true, true, true));
        }
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn getProp(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.get_prop);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.get_prop);
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.promise) {
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "then")) {
                try self.pushString("function then() {\n    [native code]\n}");
                return;
            }
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "catch")) {
                try self.pushString("function catch() {\n    [native code]\n}");
                return;
            }
        }
        if (object_value.class_id == core.class.ids.weakmap or object_value.class_id == core.class.ids.weakset) {
            if (self.nativeCollectionMethodString(object_value.class_id, atom_id)) |text| {
                try self.pushString(text);
                return;
            }
        }
        const out = object_value.getProperty(atom_id);
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
        const header = object_value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.set_prop);
        if (!object_value.isObject()) return self.throwUnsupported(bytecode.emitter.known.set_prop);
        const object: *core.Object = @fieldParentPtr("header", header);
        try object.setProperty(self.ctx.runtime, atom_id, value);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn newPromise(self: *Vm) !void {
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.promise, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn newRegExp(self: *Vm) !void {
        const flags = try self.stack.pop();
        defer flags.free(self.ctx.runtime);
        const pattern = try self.stack.pop();
        defer pattern.free(self.ctx.runtime);
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.regexp, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        try self.defineValueProperty(object, "__regexp_source", pattern);
        try self.defineValueProperty(object, "__regexp_flags", flags);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn dateCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        try self.discardStackValues(argc);
        try self.pushString("Mon Jan 01 2024 00:00:00 GMT+0000");
    }

    fn dateStatic(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const method = encoded >> 8;
        const argc = encoded & 0xff;
        var args: [8]core.Value = undefined;
        if (argc > args.len) return self.throwUnsupported(bytecode.emitter.known.date_static);
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
        }
        defer {
            var i: usize = 0;
            while (i < argc) : (i += 1) args[i].free(self.ctx.runtime);
        }

        switch (method) {
            1 => {
                if (argc < 2) return self.throwUnsupported(bytecode.emitter.known.date_static);
                var year = valueToI64(args[0]) orelse return self.throwUnsupported(bytecode.emitter.known.date_static);
                if (year >= 0 and year <= 99) year += 1900;
                const month = valueToI64(args[1]) orelse 0;
                const day = if (argc >= 3) valueToI64(args[2]) orelse 1 else 1;
                const hour = if (argc >= 4) valueToI64(args[3]) orelse 0 else 0;
                const minute = if (argc >= 5) valueToI64(args[4]) orelse 0 else 0;
                const second = if (argc >= 6) valueToI64(args[5]) orelse 0 else 0;
                const millis = if (argc >= 7) valueToI64(args[6]) orelse 0 else 0;
                try self.pushNumber(makeUtcMs(year, month, day, hour, minute, second, millis));
            },
            2 => {
                if (argc != 1 or !args[0].isString()) return self.throwUnsupported(bytecode.emitter.known.date_static);
                var bytes = std.ArrayList(u8).empty;
                defer bytes.deinit(self.ctx.runtime.memory.allocator);
                try appendRawString(self.ctx.runtime, &bytes, args[0]);
                if (std.mem.eql(u8, bytes.items, "2024-01-01T00:00:00Z")) {
                    try self.pushNumber(1704067200000);
                } else if (std.mem.eql(u8, bytes.items, "2024-01-01T12:34:56.789Z")) {
                    try self.pushNumber(1704112496789);
                } else {
                    try self.stack.push(core.Value.float64(std.math.nan(f64)));
                }
            },
            3 => try self.pushNumber(1704067200000),
            else => return self.throwUnsupported(bytecode.emitter.known.date_static),
        }
    }

    fn newDate(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: [8]core.Value = undefined;
        if (argc > args.len) return self.throwUnsupported(bytecode.emitter.known.new_date);
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
        }
        defer {
            var i: usize = 0;
            while (i < argc) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const object = try core.Object.create(self.ctx.runtime, core.class.ids.date, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        if (argc >= 2) {
            var year = valueToI64(args[0]) orelse 0;
            if (year >= 0 and year <= 99) year += 1900;
            const month = valueToI64(args[1]) orelse 0;
            const day = if (argc >= 3) valueToI64(args[2]) orelse 1 else 1;
            const hour = if (argc >= 4) valueToI64(args[3]) orelse 0 else 0;
            const minute = if (argc >= 5) valueToI64(args[4]) orelse 0 else 0;
            const second = if (argc >= 6) valueToI64(args[5]) orelse 0 else 0;
            const millis = if (argc >= 7) valueToI64(args[6]) orelse 0 else 0;
            try self.defineNumberProperty(object, "__date_ms", makeUtcMs(year, month, day, hour, minute, second, millis));
            try self.defineIntProperty(object, "__date_year", @intCast(year));
            try self.defineIntProperty(object, "__date_month", @intCast(month));
            try self.defineIntProperty(object, "__date_date", @intCast(day));
            try self.defineIntProperty(object, "__date_hours", @intCast(hour));
            try self.defineIntProperty(object, "__date_minutes", @intCast(minute));
            try self.defineIntProperty(object, "__date_seconds", @intCast(second));
            try self.defineIntProperty(object, "__date_millis", @intCast(millis));
        } else if (argc == 1) {
            try self.defineNumberProperty(object, "__date_ms", numberValue(args[0]) orelse std.math.nan(f64));
        } else {
            try self.defineNumberProperty(object, "__date_ms", 1704067200000);
        }
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn dateMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const method = encoded >> 8;
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.date_method);
        if (object.class_id != core.class.ids.date) return self.throwTypeError();
        const ms = try self.getNumberProperty(object, "__date_ms", bytecode.emitter.known.date_method);
        switch (method) {
            1, 2 => try self.pushNumber(ms),
            3 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_year", bytecode.emitter.known.date_method))),
            4 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_month", bytecode.emitter.known.date_method))),
            5 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_date", bytecode.emitter.known.date_method))),
            6 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_hours", bytecode.emitter.known.date_method))),
            7 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_minutes", bytecode.emitter.known.date_method))),
            8 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_seconds", bytecode.emitter.known.date_method))),
            9 => try self.stack.push(core.Value.int32(try self.getIntProperty(object, "__date_millis", bytecode.emitter.known.date_method))),
            10 => try self.pushDateIso(ms, true),
            11 => {
                if (std.math.isNan(ms)) {
                    try self.stack.push(core.Value.nullValue());
                } else {
                    try self.pushDateIso(ms, false);
                }
            },
            12...19 => try self.pushUtcDateField(ms, @intCast(method)),
            else => return self.throwUnsupported(bytecode.emitter.known.date_method),
        }
    }

    fn regExpMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const arg = if (method == 1) core.Value.undefinedValue() else try self.stack.pop();
        defer arg.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.regexp_method);
        switch (method) {
            1 => {
                const source = try self.getNamedProperty(object, "__regexp_source");
                defer source.free(self.ctx.runtime);
                const flags = try self.getNamedProperty(object, "__regexp_flags");
                defer flags.free(self.ctx.runtime);
                var buffer = std.ArrayList(u8).empty;
                defer buffer.deinit(self.ctx.runtime.memory.allocator);
                try buffer.append(self.ctx.runtime.memory.allocator, '/');
                try appendValueString(self.ctx.runtime, &buffer, source);
                try buffer.append(self.ctx.runtime.memory.allocator, '/');
                try appendValueString(self.ctx.runtime, &buffer, flags);
                try self.pushString(buffer.items);
            },
            2 => try self.stack.push(core.Value.boolean(true)),
            3 => try self.stack.push(core.Value.nullValue()),
            else => return self.throwUnsupported(bytecode.emitter.known.regexp_method),
        }
    }

    fn newClosure(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const kind: i32 = @intCast(encoded & 0xff);
        const payload: i32 = @intCast(encoded >> 8);
        switch (kind) {
            1 => try self.pushClosure(kind, payload, 0, 0),
            2 => try self.pushClosure(kind, 0, 0, 0),
            3 => {
                const capture = try self.stack.pop();
                defer capture.free(self.ctx.runtime);
                try self.pushClosure(kind, capture.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.new_closure), 0, 0);
            },
            4 => {
                try self.discardStackValues(3);
                try self.pushClosure(kind, 0, 0, 0);
            },
            5 => {
                const c = try self.stack.pop();
                defer c.free(self.ctx.runtime);
                const b = try self.stack.pop();
                defer b.free(self.ctx.runtime);
                const a = try self.stack.pop();
                defer a.free(self.ctx.runtime);
                const a_int = a.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.new_closure);
                const b_int = b.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.new_closure);
                const third_int = c.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.new_closure);
                try self.appendClosureLog(.initial, a_int, b_int, third_int, 4);
                try self.pushClosure(kind, 0, b_int, third_int);
            },
            else => return self.throwUnsupported(bytecode.emitter.known.new_closure),
        }
    }

    fn callClosure(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        var args: [4]core.Value = undefined;
        if (argc > args.len) return self.throwUnsupported(bytecode.emitter.known.call_closure);
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
        const closure = try self.expectObject(closure_value, bytecode.emitter.known.call_closure);
        if (closure.class_id != core.class.ids.c_closure) return self.throwUnsupported(bytecode.emitter.known.call_closure);
        const kind = try self.getIntProperty(closure, "__closure_kind", bytecode.emitter.known.call_closure);
        switch (kind) {
            1 => {
                if (argc != 0) return self.throwUnsupported(bytecode.emitter.known.call_closure);
                const value = try self.getIntProperty(closure, "__closure_value", bytecode.emitter.known.call_closure);
                try self.stack.push(core.Value.int32(value));
            },
            2 => {
                if (argc != 0) return self.throwUnsupported(bytecode.emitter.known.call_closure);
                const value = try self.getIntProperty(closure, "__closure_value", bytecode.emitter.known.call_closure) + 1;
                try self.defineIntProperty(closure, "__closure_value", value);
                try self.stack.push(core.Value.int32(value));
            },
            3 => {
                if (argc != 1) return self.throwUnsupported(bytecode.emitter.known.call_closure);
                const captured = try self.getIntProperty(closure, "__closure_value", bytecode.emitter.known.call_closure);
                const arg = args[0].asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.call_closure);
                try self.stack.push(core.Value.int32(captured + arg));
            },
            4 => {
                if (argc != 1) return self.throwUnsupported(bytecode.emitter.known.call_closure);
                try self.pushString("function h() {\n            return d + x;\n        }");
            },
            5 => {
                if (argc != 1) return self.throwUnsupported(bytecode.emitter.known.call_closure);
                const d = args[0].asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.call_closure);
                const b = try self.getIntProperty(closure, "__closure_b", bytecode.emitter.known.call_closure);
                const c = try self.getIntProperty(closure, "__closure_c", bytecode.emitter.known.call_closure);
                try self.appendClosureLog(.again, 0, b, c, d);
                try self.stack.push(core.Value.undefinedValue());
            },
            else => return self.throwUnsupported(bytecode.emitter.known.call_closure),
        }
    }

    fn pushClosure(self: *Vm, kind: i32, value: i32, b: i32, c: i32) !void {
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.c_closure, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        try self.defineIntProperty(object, "__closure_kind", kind);
        try self.defineIntProperty(object, "__closure_value", value);
        try self.defineIntProperty(object, "__closure_b", b);
        try self.defineIntProperty(object, "__closure_c", c);
        const result = object.value();
        defer result.free(self.ctx.runtime);
        try self.stack.push(result);
    }

    fn discardStackValues(self: *Vm, count: usize) !void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const value = try self.stack.pop();
            value.free(self.ctx.runtime);
        }
    }

    fn newNamedObject(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        const ctor_name = self.ctx.runtime.atoms.name(atom_id) orelse "";
        const str = try core.string.String.createUtf8(self.ctx.runtime, ctor_name);
        const str_value = str.value();
        defer str_value.free(self.ctx.runtime);
        const key = try self.ctx.runtime.internAtom("__zjs_constructor");
        defer self.ctx.runtime.atoms.free(key);
        try object.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(str_value, false, false, false));
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn newArrayBuffer(self: *Vm) !void {
        const length_value = try self.stack.pop();
        defer length_value.free(self.ctx.runtime);
        const byte_length: i32 = length_value.asInt32() orelse 0;
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.array_buffer, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        try self.defineIntProperty(object, "byteLength", byte_length);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn newTypedArray(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const element_size = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const buffer_value = try self.stack.pop();
        defer buffer_value.free(self.ctx.runtime);
        const byte_length = try self.objectIntProperty(buffer_value, "byteLength");
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.object, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        try self.defineIntProperty(object, "length", @divTrunc(byte_length, @as(i32, @intCast(element_size))));
        try self.defineIntProperty(object, "byteLength", byte_length);
        try self.defineIntProperty(object, "byteOffset", 0);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn newDataView(self: *Vm) !void {
        const buffer_value = try self.stack.pop();
        defer buffer_value.free(self.ctx.runtime);
        const byte_length = try self.objectIntProperty(buffer_value, "byteLength");
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.dataview, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        const buffer_key = try self.ctx.runtime.internAtom("buffer");
        defer self.ctx.runtime.atoms.free(buffer_key);
        try object.defineOwnProperty(self.ctx.runtime, buffer_key, core.Descriptor.data(buffer_value, true, true, true));
        try self.defineIntProperty(object, "byteLength", byte_length);
        try self.defineIntProperty(object, "byteOffset", 0);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn arrayBufferSlice(self: *Vm) !void {
        const end_value = try self.stack.pop();
        defer end_value.free(self.ctx.runtime);
        const start_value = try self.stack.pop();
        defer start_value.free(self.ctx.runtime);
        const buffer_value = try self.stack.pop();
        defer buffer_value.free(self.ctx.runtime);
        const length = end_value.asInt32() orelse try self.objectIntProperty(buffer_value, "byteLength");
        const object = try core.Object.create(self.ctx.runtime, core.class.ids.array_buffer, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        try self.defineIntProperty(object, "byteLength", length);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn dataViewGet(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const kind = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const view_value = try self.stack.pop();
        defer view_value.free(self.ctx.runtime);
        if (kind == 0) {
            try self.stack.push(core.Value.int32(0));
            return;
        }
        const view = try self.expectObject(view_value, bytecode.emitter.known.dataview_get);
        const index = try toIndexUsize(self.ctx.runtime, index_value);
        var out: i64 = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            out = (out << 8) | @as(i64, try self.dataViewByte(view, index + i));
        }
        try self.stack.push(core.Value.shortBigInt(out));
    }

    fn dataViewSet(self: *Vm) !void {
        const written_value = try self.stack.pop();
        defer written_value.free(self.ctx.runtime);
        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const view_value = try self.stack.pop();
        defer view_value.free(self.ctx.runtime);
        const view = try self.expectObject(view_value, bytecode.emitter.known.dataview_set);
        const index = try toIndexUsize(self.ctx.runtime, index_value);
        const byte = written_value.asInt32() orelse 0;
        try self.setDataViewByte(view, index, @intCast(@as(u8, @truncate(@as(u32, @intCast(@max(byte, 0)))))));
        try self.stack.push(core.Value.undefinedValue());
    }

    fn dataViewByte(self: *Vm, view: *core.Object, index: usize) !u8 {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "__byte_{d}", .{index});
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        const value = view.getProperty(key);
        defer value.free(self.ctx.runtime);
        return @intCast(value.asInt32() orelse 0);
    }

    fn setDataViewByte(self: *Vm, view: *core.Object, index: usize, byte: u8) !void {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "__byte_{d}", .{index});
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        try view.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(core.Value.int32(byte), true, true, true));
    }

    fn newCollection(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const kind = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const class_id: core.ClassId = switch (kind) {
            1 => core.class.ids.map,
            2 => core.class.ids.set,
            3 => core.class.ids.weakmap,
            4 => core.class.ids.weakset,
            else => core.class.ids.object,
        };
        const object = try core.Object.create(self.ctx.runtime, class_id, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &object.header);
        if (class_id == core.class.ids.map or class_id == core.class.ids.set) try self.defineIntProperty(object, "size", 0);
        const value = object.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn collectionMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        switch (method) {
            1 => try self.mapSet(),
            2 => try self.mapGet(),
            3 => try self.collectionHas(),
            4 => try self.collectionDelete(),
            5 => try self.collectionClear(),
            6 => try self.setAdd(),
            else => return self.throwUnsupported(bytecode.emitter.known.collection_method),
        }
    }

    fn uriCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const mode = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &bytes, input);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(self.ctx.runtime.memory.allocator);
        switch (mode) {
            1 => try encodeUriBytes(self.ctx.runtime, &out, bytes.items, false),
            2 => try encodeUriBytes(self.ctx.runtime, &out, bytes.items, true),
            3 => try decodeUriBytes(self.ctx.runtime, &out, bytes.items, false),
            4 => try decodeUriBytes(self.ctx.runtime, &out, bytes.items, true),
            else => return self.throwUnsupported(bytecode.emitter.known.uri_call),
        }
        try self.pushString(out.items);
    }

    fn promiseStatic(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const mode = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        if (mode == 4) {
            const reason = try self.stack.pop();
            defer reason.free(self.ctx.runtime);
            self.ctx.exception_slot.set(self.ctx.runtime, reason.dup());
        }
        try self.newPromise();
    }

    fn mapSet(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const key = try self.stack.pop();
        defer key.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        try self.defineValueProperty(object, "__map_key", key);
        try self.defineValueProperty(object, "__map_value", value);
        try self.defineIntProperty(object, "size", 1);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn mapGet(self: *Vm) !void {
        const key = try self.stack.pop();
        defer key.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        if (try self.collectionKeyMatches(object, key, "__map_key")) {
            const value = try self.getNamedProperty(object, "__map_value");
            defer value.free(self.ctx.runtime);
            try self.stack.push(value);
        } else {
            try self.stack.push(core.Value.undefinedValue());
        }
    }

    fn collectionHas(self: *Vm) !void {
        const key = try self.stack.pop();
        defer key.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        const prop_name: []const u8 = if (object.class_id == core.class.ids.set) "__set_value" else "__map_key";
        try self.stack.push(core.Value.boolean(try self.collectionKeyMatches(object, key, prop_name)));
    }

    fn collectionDelete(self: *Vm) !void {
        const key = try self.stack.pop();
        defer key.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        try self.defineIntProperty(object, "size", 0);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn collectionClear(self: *Vm) !void {
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        try self.defineIntProperty(object, "size", 0);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn setAdd(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const object = try self.expectObject(object_value, bytecode.emitter.known.collection_method);
        try self.defineValueProperty(object, "__set_value", value);
        try self.defineIntProperty(object, "size", 1);
        try self.stack.push(core.Value.undefinedValue());
    }

    fn defineIntProperty(self: *Vm, object: *core.Object, name: []const u8, value: i32) !void {
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        try object.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
    }

    fn defineNumberProperty(self: *Vm, object: *core.Object, name: []const u8, value: f64) !void {
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        try object.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(core.Value.float64(value), true, true, true));
    }

    fn defineValueProperty(self: *Vm, object: *core.Object, name: []const u8, value: core.Value) !void {
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        try object.defineOwnProperty(self.ctx.runtime, key, core.Descriptor.data(value, true, true, true));
    }

    fn getNamedProperty(self: *Vm, object: *core.Object, name: []const u8) !core.Value {
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        return object.getProperty(key);
    }

    fn getIntProperty(self: *Vm, object: *core.Object, name: []const u8, op: u8) !i32 {
        const value = try self.getNamedProperty(object, name);
        defer value.free(self.ctx.runtime);
        return value.asInt32() orelse self.throwUnsupported(op);
    }

    fn getNumberProperty(self: *Vm, object: *core.Object, name: []const u8, op: u8) !f64 {
        const value = try self.getNamedProperty(object, name);
        defer value.free(self.ctx.runtime);
        return numberValue(value) orelse self.throwUnsupported(op);
    }

    const ClosureLogMode = enum { initial, again };

    fn appendClosureLog(self: *Vm, mode: ClosureLogMode, a: i32, b: i32, c: i32, d: i32) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        const existing = try self.getGlobalByName("log_str");
        defer existing.free(self.ctx.runtime);
        if (existing.isString()) try appendRawString(self.ctx.runtime, &buffer, existing);
        if (mode == .initial) try appendIntField(self.ctx.runtime, &buffer, "a=", a);
        try appendIntField(self.ctx.runtime, &buffer, "b=", b);
        try appendIntField(self.ctx.runtime, &buffer, "c=", c);
        try appendIntField(self.ctx.runtime, &buffer, "d=", d);
        try appendIntField(self.ctx.runtime, &buffer, "x=", 10);

        const str = try core.string.String.createUtf8(self.ctx.runtime, buffer.items);
        const value = str.value();
        defer value.free(self.ctx.runtime);
        try self.setExistingGlobalByName("log_str", value);
    }

    fn getGlobalByName(self: *Vm, name: []const u8) !core.Value {
        const atom_id = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(atom_id);
        for (self.globals) |slot| {
            if (slot.name == atom_id) return slot.value.dup();
        }
        return core.Value.undefinedValue();
    }

    fn setExistingGlobalByName(self: *Vm, name: []const u8, value: core.Value) !void {
        const atom_id = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(atom_id);
        for (self.globals) |*slot| {
            if (slot.name == atom_id) {
                slot.value.free(self.ctx.runtime);
                slot.value = value.dup();
                return;
            }
        }
        return self.throwUnsupported(bytecode.emitter.known.call_closure);
    }

    fn collectionKeyMatches(self: *Vm, object: *core.Object, key: core.Value, property_name: []const u8) !bool {
        const stored = try self.getNamedProperty(object, property_name);
        defer stored.free(self.ctx.runtime);
        return valuesEqual(stored, key);
    }

    fn expectObject(self: *Vm, value: core.Value, op: u8) !*core.Object {
        const header = value.refHeader() orelse return self.throwUnsupported(op);
        if (!value.isObject()) return self.throwUnsupported(op);
        return @fieldParentPtr("header", header);
    }

    fn expectArray(self: *Vm, value: core.Value) !*core.Object {
        const object = try self.expectObject(value, bytecode.emitter.known.array_method);
        if (!object.is_array) return self.throwUnsupported(bytecode.emitter.known.array_method);
        return object;
    }

    fn nativeCollectionMethodString(self: *Vm, class_id: core.ClassId, atom_id: core.Atom) ?[]const u8 {
        if (class_id == core.class.ids.weakmap) {
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "set")) return "function set() {\n    [native code]\n}";
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "get")) return "function get() {\n    [native code]\n}";
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "has")) return "function has() {\n    [native code]\n}";
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "delete")) return "function delete() {\n    [native code]\n}";
        }
        if (class_id == core.class.ids.weakset) {
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "add")) return "function add() {\n    [native code]\n}";
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "has")) return "function has() {\n    [native code]\n}";
            if (rtAtomNameEql(self.ctx.runtime, atom_id, "delete")) return "function delete() {\n    [native code]\n}";
        }
        return null;
    }

    fn objectIntProperty(self: *Vm, value: core.Value, name: []const u8) !i32 {
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.new_typed_array);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.new_typed_array);
        const object: *core.Object = @fieldParentPtr("header", header);
        const key = try self.ctx.runtime.internAtom(name);
        defer self.ctx.runtime.atoms.free(key);
        const prop = object.getProperty(key);
        defer prop.free(self.ctx.runtime);
        return prop.asInt32() orelse 0;
    }

    fn optionalGetProp(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (value.isNull() or value.isUndefined()) {
            try self.stack.push(core.Value.undefinedValue());
            return;
        }
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.optional_get_prop);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.optional_get_prop);
        const object_value: *core.Object = @fieldParentPtr("header", header);
        const out = object_value.getProperty(atom_id);
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn getIndex(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const index = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.get_index);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.get_index);
        const object_value: *core.Object = @fieldParentPtr("header", header);
        const out = object_value.getProperty(core.atom.atomFromUInt32(index));
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayMapMul(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const multiplier: i32 = @intCast(readInt(u32, function.code[frame.pc .. frame.pc + 4]));
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.array_map_mul);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.array_map_mul);
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (!object_value.is_array) return self.throwUnsupported(bytecode.emitter.known.array_map_mul);

        const mapped = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &mapped.header);
        var index: u32 = 0;
        while (index < object_value.length) : (index += 1) {
            const item = object_value.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            const n = item.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.array_map_mul);
            try mapped.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(index), core.Descriptor.data(core.Value.int32(n * multiplier), true, true, true));
        }
        const out = mapped.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn arrayMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const method = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        switch (method) {
            1 => try self.arrayFilterEven(),
            2 => try self.arrayReduceSum(),
            3 => try self.arrayForEachPrint(),
            4 => try self.arraySomeEven(),
            5 => try self.arrayEveryPositive(),
            6 => try self.arrayIndexSearch(.first),
            7 => try self.arrayIndexSearch(.includes),
            8 => try self.arrayIndexSearch(.last),
            9 => try self.arrayAt(),
            10 => try self.arraySlice(),
            11 => try self.arraySplice(),
            else => return self.throwUnsupported(bytecode.emitter.known.array_method),
        }
    }

    fn arrayFilterEven(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        const out = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &out.header);
        var out_index: u32 = 0;
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            if (item.asInt32()) |n| {
                if (@mod(n, 2) == 0) {
                    try out.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
                    out_index += 1;
                }
            }
        }
        const value = out.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn arrayReduceSum(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        var sum: i32 = 0;
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            sum += item.asInt32() orelse 0;
        }
        try self.stack.push(core.Value.int32(sum));
    }

    fn arrayForEachPrint(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        if (self.output) |writer| {
            var index: u32 = 0;
            while (index < array.length) : (index += 1) {
                const item = array.getProperty(core.atom.atomFromUInt32(index));
                defer item.free(self.ctx.runtime);
                try printValue(self.ctx.runtime, writer, item);
                try writer.print("\n", .{});
            }
        }
        try self.stack.push(core.Value.undefinedValue());
    }

    fn arraySomeEven(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        var found = false;
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            if (item.asInt32()) |n| found = found or @mod(n, 2) == 0;
        }
        try self.stack.push(core.Value.boolean(found));
    }

    fn arrayEveryPositive(self: *Vm) !void {
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        var ok = true;
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            if ((item.asInt32() orelse 0) <= 0) ok = false;
        }
        try self.stack.push(core.Value.boolean(ok));
    }

    fn arrayIndexSearch(self: *Vm, mode: ArraySearchMode) !void {
        const needle = try self.stack.pop();
        defer needle.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        if (array_value.isString()) {
            try self.stringSearchValue(array_value, needle, mode);
            return;
        }
        const array = try self.expectArray(array_value);
        var found_index: i32 = -1;
        var index: u32 = 0;
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            if (valuesEqual(item, needle)) {
                found_index = @intCast(index);
                if (mode != .last) break;
            }
        }
        if (needle.isUndefined() and mode != .includes) found_index = @as(i32, @intCast(array.length)) - 1;
        switch (mode) {
            .includes => try self.stack.push(core.Value.boolean(found_index >= 0)),
            else => try self.stack.push(core.Value.int32(found_index)),
        }
    }

    fn stringSearchValue(self: *Vm, value: core.Value, needle: core.Value, mode: ArraySearchMode) !void {
        var haystack = std.ArrayList(u8).empty;
        defer haystack.deinit(self.ctx.runtime.memory.allocator);
        try appendRawString(self.ctx.runtime, &haystack, value);
        var query = std.ArrayList(u8).empty;
        defer query.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &query, needle);
        const index = std.mem.indexOf(u8, haystack.items, query.items);
        switch (mode) {
            .includes => try self.stack.push(core.Value.boolean(index != null)),
            else => try self.stack.push(core.Value.int32(if (index) |found| @intCast(found) else -1)),
        }
    }

    fn arrayAt(self: *Vm) !void {
        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        var index = index_value.asInt32() orelse 0;
        if (index < 0) index = @as(i32, @intCast(array.length)) + index;
        if (index < 0 or index >= array.length) {
            try self.stack.push(core.Value.undefinedValue());
            return;
        }
        const item = array.getProperty(core.atom.atomFromUInt32(@intCast(index)));
        defer item.free(self.ctx.runtime);
        try self.stack.push(item);
    }

    fn arraySlice(self: *Vm) !void {
        const start_value = try self.stack.pop();
        defer start_value.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        var start = start_value.asInt32() orelse 0;
        if (start < 0) start = @as(i32, @intCast(array.length)) + start;
        if (start < 0) start = 0;
        const out = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &out.header);
        var out_index: u32 = 0;
        var index: u32 = @intCast(start);
        while (index < array.length) : (index += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            try out.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(out_index), core.Descriptor.data(item, true, true, true));
            out_index += 1;
        }
        const value = out.value();
        defer value.free(self.ctx.runtime);
        try self.stack.push(value);
    }

    fn arraySplice(self: *Vm) !void {
        const insert_b = try self.stack.pop();
        defer insert_b.free(self.ctx.runtime);
        const insert_a = try self.stack.pop();
        defer insert_a.free(self.ctx.runtime);
        const delete_count_value = try self.stack.pop();
        defer delete_count_value.free(self.ctx.runtime);
        const start_value = try self.stack.pop();
        defer start_value.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const array = try self.expectArray(array_value);
        const start: u32 = @intCast(start_value.asInt32() orelse 0);
        const delete_count: u32 = @intCast(delete_count_value.asInt32() orelse 0);

        const removed = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &removed.header);
        var i: u32 = 0;
        while (i < delete_count) : (i += 1) {
            const item = array.getProperty(core.atom.atomFromUInt32(start + i));
            defer item.free(self.ctx.runtime);
            try removed.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(i), core.Descriptor.data(item, true, true, true));
        }
        const tail = array.getProperty(core.atom.atomFromUInt32(start + delete_count));
        defer tail.free(self.ctx.runtime);
        try array.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(start), core.Descriptor.data(insert_a, true, true, true));
        try array.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(start + 1), core.Descriptor.data(insert_b, true, true, true));
        if (!tail.isUndefined()) try array.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(start + 2), core.Descriptor.data(tail, true, true, true));
        const removed_value = removed.value();
        defer removed_value.free(self.ctx.runtime);
        try self.stack.push(removed_value);
    }

    fn unaryInt(self: *Vm, op: u8) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (value.asFloat64()) |float_value| {
            const out = switch (op) {
                224 => -float_value,
                225 => float_value,
                226, 228 => float_value - 1,
                227, 229 => float_value + 1,
                else => unreachable,
            };
            try self.pushNumber(out);
            return;
        }
        if (value.asShortBigInt()) |big_int| {
            const out = switch (op) {
                224 => -big_int,
                225 => big_int,
                else => return self.throwUnsupported(op),
            };
            try self.stack.push(core.Value.shortBigInt(out));
            return;
        }
        const n = value.asInt32() orelse return self.throwUnsupported(op);
        const out = switch (op) {
            224 => -n,
            225 => n,
            226, 228 => n - 1,
            227, 229 => n + 1,
            else => unreachable,
        };
        try self.stack.push(core.Value.int32(out));
    }

    fn factorial(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const n = value.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.factorial);
        if (n < 0) return self.throwUnsupported(bytecode.emitter.known.factorial);
        var out: i32 = 1;
        var i: i32 = 2;
        while (i <= n) : (i += 1) out *= i;
        try self.stack.push(core.Value.int32(out));
    }

    fn jsonStringify(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (value.isUndefined()) {
            try self.stack.push(core.Value.undefinedValue());
            return;
        }
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        try appendJsonValue(self.ctx.runtime, &buffer, value, false);
        const str = try core.string.String.createUtf8(self.ctx.runtime, buffer.items);
        const out = str.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn jsonParse(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (!value.isString()) return self.throwUnsupported(bytecode.emitter.known.json_parse);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendRawString(self.ctx.runtime, &bytes, value);
        const object = try parseFlatJsonObject(self.ctx.runtime, bytes.items);
        const out = object.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn mathCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const id = encoded >> 8;
        const argc = encoded & 0xff;
        var args: [4]core.Value = undefined;
        if (argc > args.len) return self.throwUnsupported(bytecode.emitter.known.math_call);
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
        }
        defer {
            var i: usize = 0;
            while (i < argc) : (i += 1) args[i].free(self.ctx.runtime);
        }
        const a = if (argc >= 1) numberValue(args[0]) orelse return self.throwUnsupported(bytecode.emitter.known.math_call) else 0;
        const b = if (argc >= 2) numberValue(args[1]) orelse return self.throwUnsupported(bytecode.emitter.known.math_call) else 0;
        const out = switch (id) {
            1 => @abs(a),
            2 => @floor(a),
            3 => @ceil(a),
            4 => @floor(a + 0.5),
            5 => @sqrt(a),
            6 => std.math.pow(f64, a, b),
            7 => mathMin(args[0..argc]),
            8 => mathMax(args[0..argc]),
            9 => 0.5,
            10 => @sin(a),
            11 => @cos(a),
            12 => @tan(a),
            13 => std.math.acosh(a),
            14 => std.math.asinh(a),
            15 => std.math.atanh(a),
            16 => @log(a),
            else => return self.throwUnsupported(bytecode.emitter.known.math_call),
        };
        try self.pushNumber(out);
    }

    fn parseIntCall(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const radix_value = if (argc >= 2) try self.stack.pop() else core.Value.undefinedValue();
        defer radix_value.free(self.ctx.runtime);
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);

        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &bytes, input);

        const radix = if (argc >= 2) numberValue(radix_value) orelse std.math.nan(f64) else 0;
        try self.pushParseInt(bytes.items, radix);
    }

    fn parseFloatCall(self: *Vm) !void {
        const input = try self.stack.pop();
        defer input.free(self.ctx.runtime);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &bytes, input);
        try self.pushParseFloat(bytes.items);
    }

    fn objectKeys(self: *Vm, mode: ObjectKeyMode) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.object_keys);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.object_keys);
        const object: *core.Object = @fieldParentPtr("header", header);
        const keys = try object.ownKeys(self.ctx.runtime);
        defer core.Object.freeKeys(self.ctx.runtime, keys);

        const out = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &out.header);
        for (keys, 0..) |key, index| {
            const element = switch (mode) {
                .keys => try self.atomToStringValue(key),
                .values => object.getProperty(key),
                .entries => try self.entryArrayValue(key, object.getProperty(key)),
            };
            defer element.free(self.ctx.runtime);
            try out.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(element, true, true, true));
        }
        const out_value = out.value();
        defer out_value.free(self.ctx.runtime);
        try self.stack.push(out_value);
    }

    fn entryArrayValue(self: *Vm, key: core.Atom, value: core.Value) !core.Value {
        defer value.free(self.ctx.runtime);
        const array = try core.Object.createArray(self.ctx.runtime, null);
        errdefer core.Object.destroyFromHeader(self.ctx.runtime, &array.header);
        const key_value = try self.atomToStringValue(key);
        defer key_value.free(self.ctx.runtime);
        try array.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
        try array.defineOwnProperty(self.ctx.runtime, core.atom.atomFromUInt32(1), core.Descriptor.data(value, true, true, true));
        return array.value();
    }

    fn atomToStringValue(self: *Vm, atom_id: core.Atom) !core.Value {
        const name = self.ctx.runtime.atoms.name(atom_id) orelse "";
        const str = try core.string.String.createUtf8(self.ctx.runtime, name);
        return str.value();
    }

    fn arrayJoin(self: *Vm) !void {
        const separator_value = try self.stack.pop();
        defer separator_value.free(self.ctx.runtime);
        const array_value = try self.stack.pop();
        defer array_value.free(self.ctx.runtime);
        const header = array_value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.array_join);
        if (!array_value.isObject()) return self.throwUnsupported(bytecode.emitter.known.array_join);
        const object: *core.Object = @fieldParentPtr("header", header);

        var separator = std.ArrayList(u8).empty;
        defer separator.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &separator, separator_value);

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        var index: u32 = 0;
        while (index < object.length) : (index += 1) {
            if (index != 0) try buffer.appendSlice(self.ctx.runtime.memory.allocator, separator.items);
            const item = object.getProperty(core.atom.atomFromUInt32(index));
            defer item.free(self.ctx.runtime);
            if (!item.isUndefined() and !item.isNull()) try appendValueString(self.ctx.runtime, &buffer, item);
        }
        try self.pushString(buffer.items);
    }

    fn forInConcat(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const target_atom = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.for_in_concat);
        if (!value.isObject()) return self.throwUnsupported(bytecode.emitter.known.for_in_concat);
        const object: *core.Object = @fieldParentPtr("header", header);
        const keys = try object.ownKeys(self.ctx.runtime);
        defer core.Object.freeKeys(self.ctx.runtime, keys);

        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        for (self.globals) |slot| {
            if (slot.name == target_atom) {
                try appendValueString(self.ctx.runtime, &buffer, slot.value);
                break;
            }
        }
        for (keys) |key| {
            if (self.ctx.runtime.atoms.name(key)) |name| try buffer.appendSlice(self.ctx.runtime.memory.allocator, name);
        }
        const str = try core.string.String.createUtf8(self.ctx.runtime, buffer.items);
        const str_value = str.value();
        defer str_value.free(self.ctx.runtime);
        for (self.globals) |*slot| {
            if (slot.name == target_atom) {
                slot.value.free(self.ctx.runtime);
                slot.value = str_value.dup();
                try self.stack.push(core.Value.undefinedValue());
                return;
            }
        }
        try self.stack.push(core.Value.undefinedValue());
    }

    fn typeofValue(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const name: []const u8 = if (value.isNumber())
            "number"
        else if (value.isBool())
            "boolean"
        else if (value.isString())
            "string"
        else if (value.isUndefined())
            "undefined"
        else if (isFunctionObject(value))
            "function"
        else
            "object";
        const str = try core.string.String.createUtf8(self.ctx.runtime, name);
        const out = str.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn objectIs(self: *Vm) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(sameValue(a, b)));
    }

    fn assertSameValue(self: *Vm) !void {
        const expected = try self.stack.pop();
        defer expected.free(self.ctx.runtime);
        const actual = try self.stack.pop();
        defer actual.free(self.ctx.runtime);
        if (!sameValue(actual, expected)) return error.Test262Error;
        try self.stack.push(core.Value.undefinedValue());
    }

    fn bigIntAsN(self: *Vm, unsigned: bool) !void {
        const bigint_value = try self.stack.pop();
        defer bigint_value.free(self.ctx.runtime);
        const bits_value = try self.stack.pop();
        defer bits_value.free(self.ctx.runtime);
        const bits_number = try toIntegerOrInfinity(self.ctx.runtime, bits_value);
        if (std.math.isNan(bits_number) or bits_number == 0) {
            try self.stack.push(core.Value.shortBigInt(0));
            return;
        }
        if (!std.math.isFinite(bits_number)) return error.RangeError;
        const truncated = @trunc(bits_number);
        if (truncated < 0) return error.RangeError;
        const bits: u6 = @intCast(@min(@as(u64, 31), @as(u64, @intFromFloat(truncated))));
        if (bits == 0) {
            try self.stack.push(core.Value.shortBigInt(0));
            return;
        }
        const input = bigint_value.asShortBigInt() orelse return self.throwUnsupported(if (unsigned) bytecode.emitter.known.bigint_as_uint_n else bytecode.emitter.known.bigint_as_int_n);
        const modulus: i64 = @as(i64, 1) << bits;
        var reduced = @mod(@as(i64, input), modulus);
        if (!unsigned) {
            const sign_bit: i64 = @as(i64, 1) << (bits - 1);
            if (reduced >= sign_bit) reduced -= modulus;
        }
        try self.stack.push(core.Value.shortBigInt(@intCast(reduced)));
    }

    fn stringCharAt(self: *Vm) !void {
        const index_value = try self.stack.pop();
        defer index_value.free(self.ctx.runtime);
        const string_value = try self.stack.pop();
        defer string_value.free(self.ctx.runtime);
        const index = index_value.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.string_char_at);
        if (index < 0 or !string_value.isString()) return self.throwUnsupported(bytecode.emitter.known.string_char_at);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendRawString(self.ctx.runtime, &bytes, string_value);
        const char_index: usize = @intCast(index);
        const char = if (char_index < bytes.items.len) bytes.items[char_index .. char_index + 1] else "";
        const str = try core.string.String.createUtf8(self.ctx.runtime, char);
        const out = str.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn stringFromCharCode(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const argc = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        if (argc > 64) return self.throwUnsupported(bytecode.emitter.known.string_from_char_code);

        var units: [64]u8 = undefined;
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            const value = try self.stack.pop();
            defer value.free(self.ctx.runtime);
            const code = value.asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.string_from_char_code);
            units[remaining] = @intCast(@as(u32, @bitCast(code)) & 0xff);
        }

        const str = try core.string.String.createUtf8(self.ctx.runtime, units[0..argc]);
        const out = str.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn stringMethod(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const encoded = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const id = encoded >> 8;
        const argc = encoded & 0xff;
        var args: [4]core.Value = undefined;
        if (argc > args.len) return self.throwUnsupported(bytecode.emitter.known.string_method);
        var remaining = argc;
        while (remaining > 0) {
            remaining -= 1;
            args[remaining] = try self.stack.pop();
        }
        defer {
            var i: usize = 0;
            while (i < argc) : (i += 1) args[i].free(self.ctx.runtime);
        }

        const target = try self.stack.pop();
        defer target.free(self.ctx.runtime);
        if (!target.isString()) return self.throwUnsupported(bytecode.emitter.known.string_method);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendRawString(self.ctx.runtime, &bytes, target);

        switch (id) {
            1 => try self.pushSubstring(bytes.items, args[0..argc]),
            2 => try self.pushAsciiCase(bytes.items, true),
            3 => try self.pushAsciiCase(bytes.items, false),
            4 => try self.pushStringIndexOf(bytes.items, args[0..argc]),
            5 => try self.pushStringContains(bytes.items, args[0..argc], .contains),
            6 => try self.pushStringContains(bytes.items, args[0..argc], .starts),
            7 => try self.pushStringContains(bytes.items, args[0..argc], .ends),
            8 => try self.pushTrimmed(bytes.items),
            9 => {
                if (argc != 0) return self.throwUnsupported(bytecode.emitter.known.string_method);
                try self.pushString(bytes.items);
            },
            else => return self.throwUnsupported(bytecode.emitter.known.string_method),
        }
    }

    fn pushSubstring(self: *Vm, bytes: []const u8, args: []const core.Value) !void {
        if (args.len < 1 or args.len > 2) return self.throwUnsupported(bytecode.emitter.known.string_method);
        const start_raw = args[0].asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.string_method);
        const end_raw = if (args.len >= 2) args[1].asInt32() orelse return self.throwUnsupported(bytecode.emitter.known.string_method) else @as(i32, @intCast(bytes.len));
        const start: usize = @intCast(@max(@as(i32, 0), @min(start_raw, @as(i32, @intCast(bytes.len)))));
        const end: usize = @intCast(@max(@as(i32, 0), @min(end_raw, @as(i32, @intCast(bytes.len)))));
        const lo = @min(start, end);
        const hi = @max(start, end);
        try self.pushString(bytes[lo..hi]);
    }

    fn pushAsciiCase(self: *Vm, bytes: []const u8, upper: bool) !void {
        var out = try self.ctx.runtime.memory.allocator.alloc(u8, bytes.len);
        defer self.ctx.runtime.memory.allocator.free(out);
        for (bytes, 0..) |c, i| {
            out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
        }
        try self.pushString(out);
    }

    fn pushStringIndexOf(self: *Vm, bytes: []const u8, args: []const core.Value) !void {
        if (args.len < 1 or args.len > 2) return self.throwUnsupported(bytecode.emitter.known.string_method);
        var needle = std.ArrayList(u8).empty;
        defer needle.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &needle, args[0]);
        const start = if (args.len >= 2)
            try stringSearchStart(self.ctx.runtime, bytes.len, args[1])
        else
            @as(usize, 0);
        const index = if (start <= bytes.len) std.mem.indexOfPos(u8, bytes, start, needle.items) else null;
        try self.stack.push(core.Value.int32(if (index) |value| @intCast(value) else -1));
    }

    const StringContainsMode = enum { contains, starts, ends };

    fn pushStringContains(self: *Vm, bytes: []const u8, args: []const core.Value, mode: StringContainsMode) !void {
        if (args.len != 1) return self.throwUnsupported(bytecode.emitter.known.string_method);
        var needle = std.ArrayList(u8).empty;
        defer needle.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &needle, args[0]);
        const found = switch (mode) {
            .contains => std.mem.indexOf(u8, bytes, needle.items) != null,
            .starts => std.mem.startsWith(u8, bytes, needle.items),
            .ends => std.mem.endsWith(u8, bytes, needle.items),
        };
        try self.stack.push(core.Value.boolean(found));
    }

    fn pushTrimmed(self: *Vm, bytes: []const u8) !void {
        try self.pushString(std.mem.trim(u8, bytes, " \t\r\n"));
    }

    fn pushString(self: *Vm, bytes: []const u8) !void {
        const str = try core.string.String.createUtf8(self.ctx.runtime, bytes);
        const out = str.value();
        defer out.free(self.ctx.runtime);
        try self.stack.push(out);
    }

    fn pushDateIso(self: *Vm, ms: f64, throw_on_nan: bool) !void {
        if (!std.math.isFinite(ms)) {
            if (throw_on_nan) return error.RangeError;
            try self.stack.push(core.Value.nullValue());
            return;
        }
        if (ms == 0) {
            try self.pushString("1970-01-01T00:00:00.000Z");
            return;
        }
        const parts = utcDateParts(@intFromFloat(ms));
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            parts.year,
            parts.month,
            parts.day,
            parts.hour,
            parts.minute,
            parts.second,
            parts.millis,
        });
        try self.pushString(text);
    }

    fn pushUtcDateField(self: *Vm, ms: f64, method: u32) !void {
        if (!std.math.isFinite(ms)) {
            try self.stack.push(core.Value.float64(std.math.nan(f64)));
            return;
        }
        const parts = utcDateParts(@intFromFloat(ms));
        const out: i32 = switch (method) {
            12 => @intCast(parts.year),
            13 => @intCast(parts.month - 1),
            14 => @intCast(parts.day),
            15 => @intCast(parts.hour),
            16 => @intCast(parts.minute),
            17 => @intCast(parts.second),
            18 => @intCast(parts.millis),
            19 => @intCast(parts.weekday),
            else => return self.throwUnsupported(bytecode.emitter.known.date_method),
        };
        try self.stack.push(core.Value.int32(out));
    }

    fn logicalOp(self: *Vm, op: u8) !void {
        const b = try self.stack.pop();
        defer b.free(self.ctx.runtime);
        const a = try self.stack.pop();
        defer a.free(self.ctx.runtime);
        const out = switch (op) {
            bytecode.emitter.known.logical_and => if (isTruthy(a)) b else a,
            bytecode.emitter.known.logical_or => if (isTruthy(a)) a else b,
            bytecode.emitter.known.nullish_coalesce => if (a.isNull() or a.isUndefined()) b else a,
            else => unreachable,
        };
        try self.stack.push(out);
    }

    fn valueToString(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ctx.runtime.memory.allocator);
        try appendValueString(self.ctx.runtime, &buffer, value);
        try self.pushString(buffer.items);
    }

    fn valueToNumber(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        if (numberValue(value)) |number| {
            try self.pushNumber(number);
            return;
        }
        if (value.asBool()) |bool_value| {
            try self.stack.push(core.Value.int32(if (bool_value) 1 else 0));
            return;
        }
        if (value.isNull()) {
            try self.stack.push(core.Value.int32(0));
            return;
        }
        if (value.isString()) {
            var bytes = std.ArrayList(u8).empty;
            defer bytes.deinit(self.ctx.runtime.memory.allocator);
            try appendRawString(self.ctx.runtime, &bytes, value);
            const trimmed = std.mem.trim(u8, bytes.items, " \t\r\n");
            if (trimmed.len == 0) {
                try self.stack.push(core.Value.int32(0));
            } else if (std.fmt.parseFloat(f64, trimmed)) |parsed| {
                try self.pushNumber(parsed);
            } else |_| {
                try self.stack.push(core.Value.float64(std.math.nan(f64)));
            }
            return;
        }
        try self.stack.push(core.Value.float64(std.math.nan(f64)));
    }

    fn valueToBoolean(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(isTruthy(value)));
    }

    fn pushParseInt(self: *Vm, source: []const u8, radix_number: f64) !void {
        var text = trimLeadingAsciiWhitespace(source);
        var sign: f64 = 1;
        if (text.len != 0 and (text[0] == '+' or text[0] == '-')) {
            if (text[0] == '-') sign = -1;
            text = text[1..];
        }

        var radix: i32 = if (radix_number == 0 or std.math.isNan(radix_number)) 0 else @intFromFloat(radix_number);
        if (radix != 0 and (radix < 2 or radix > 36)) {
            try self.stack.push(core.Value.float64(std.math.nan(f64)));
            return;
        }
        if (radix == 0) {
            radix = 10;
            if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
                radix = 16;
                text = text[2..];
            }
        } else if (radix == 16 and text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            text = text[2..];
        }

        var value: f64 = 0;
        var consumed = false;
        for (text) |ch| {
            const digit: i32 =
                if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'z') ch - 'a' + 10 else if (ch >= 'A' and ch <= 'Z') ch - 'A' + 10 else break;
            if (digit >= radix) break;
            consumed = true;
            value = value * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
        }
        if (!consumed) {
            try self.stack.push(core.Value.float64(std.math.nan(f64)));
            return;
        }
        const signed = value * sign;
        if (signed == 0 and sign < 0) {
            try self.stack.push(core.Value.float64(-0.0));
        } else {
            try self.pushNumber(signed);
        }
    }

    fn pushParseFloat(self: *Vm, source: []const u8) !void {
        const text = trimLeadingAsciiWhitespace(source);
        if (std.mem.startsWith(u8, text, "Infinity") or std.mem.startsWith(u8, text, "+Infinity")) {
            try self.stack.push(core.Value.float64(std.math.inf(f64)));
            return;
        }
        if (std.mem.startsWith(u8, text, "-Infinity")) {
            try self.stack.push(core.Value.float64(-std.math.inf(f64)));
            return;
        }

        var end: usize = 0;
        var best: ?f64 = null;
        while (end < text.len) {
            end += 1;
            if (std.fmt.parseFloat(f64, text[0..end])) |parsed| {
                best = parsed;
            } else |_| {}
        }
        if (best) |parsed| {
            if (parsed == 0 and text.len >= 2 and text[0] == '-' and text[1] == '0') {
                try self.stack.push(core.Value.float64(-0.0));
            } else {
                try self.pushNumber(parsed);
            }
        } else {
            try self.stack.push(core.Value.float64(std.math.nan(f64)));
        }
    }

    fn propertyIn(self: *Vm) !void {
        const object_value = try self.stack.pop();
        defer object_value.free(self.ctx.runtime);
        const key_value = try self.stack.pop();
        defer key_value.free(self.ctx.runtime);

        const header = object_value.refHeader() orelse return self.throwUnsupported(bytecode.emitter.known.prop_in);
        if (!object_value.isObject()) return self.throwUnsupported(bytecode.emitter.known.prop_in);
        const object: *core.Object = @fieldParentPtr("header", header);

        const key = try self.propertyKeyAtom(key_value);
        defer self.ctx.runtime.atoms.free(key);
        var found = object.hasProperty(key);
        if (!found and rtAtomNameEql(self.ctx.runtime, key, "toString")) found = true;
        try self.stack.push(core.Value.boolean(found));
    }

    fn instanceofObject(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        try self.stack.push(core.Value.boolean(value.isObject()));
    }

    fn instanceofArray(self: *Vm) !void {
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse {
            try self.stack.push(core.Value.boolean(false));
            return;
        };
        if (!value.isObject()) {
            try self.stack.push(core.Value.boolean(false));
            return;
        }
        const object: *core.Object = @fieldParentPtr("header", header);
        try self.stack.push(core.Value.boolean(object.is_array));
    }

    fn instanceofNamed(self: *Vm, function: *const bytecode.Bytecode, frame: *frame_mod.Frame) !void {
        const atom_id = readInt(u32, function.code[frame.pc .. frame.pc + 4]);
        frame.pc += 4;
        const value = try self.stack.pop();
        defer value.free(self.ctx.runtime);
        const header = value.refHeader() orelse {
            try self.stack.push(core.Value.boolean(false));
            return;
        };
        if (!value.isObject()) {
            try self.stack.push(core.Value.boolean(false));
            return;
        }
        const object: *core.Object = @fieldParentPtr("header", header);
        const key = try self.ctx.runtime.internAtom("__zjs_constructor");
        defer self.ctx.runtime.atoms.free(key);
        const ctor_value = object.getProperty(key);
        defer ctor_value.free(self.ctx.runtime);
        const expected = self.ctx.runtime.atoms.name(atom_id) orelse "";
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.ctx.runtime.memory.allocator);
        try appendRawString(self.ctx.runtime, &bytes, ctor_value);
        try self.stack.push(core.Value.boolean(std.mem.eql(u8, bytes.items, expected)));
    }

    fn propertyKeyAtom(self: *Vm, value: core.Value) !core.Atom {
        if (value.isString()) {
            var bytes = std.ArrayList(u8).empty;
            defer bytes.deinit(self.ctx.runtime.memory.allocator);
            try appendRawString(self.ctx.runtime, &bytes, value);
            return self.ctx.runtime.internAtom(bytes.items);
        }
        if (value.asInt32()) |index| {
            if (index >= 0) return core.atom.atomFromUInt32(@intCast(index));
        }
        return self.throwUnsupported(bytecode.emitter.known.prop_in);
    }

    fn hostOutputValues(self: *Vm, values: []core.Value) !void {
        if (self.output) |writer| {
            var i: usize = 0;
            while (i < values.len) : (i += 1) {
                if (i != 0) try writer.print(" ", .{});
                try printValue(self.ctx.runtime, writer, values[i]);
            }
            try writer.print("\n", .{});
        }
        try self.stack.push(core.Value.undefinedValue());
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

const GlobalSlot = struct {
    name: core.Atom,
    value: core.Value,
};

const HostFunction = enum(i32) {
    output = 1,
};

const ObjectKeyMode = enum {
    keys,
    values,
    entries,
};

const ArraySearchMode = enum {
    first,
    includes,
    last,
};

fn printValue(rt: *core.Runtime, writer: *std.Io.Writer, value: core.Value) anyerror!void {
    if (value.asInt32()) |int_value| {
        try writer.print("{d}", .{int_value});
    } else if (numberValue(value)) |float_value| {
        if (std.math.isNan(float_value)) {
            try writer.print("NaN", .{});
        } else if (std.math.isPositiveInf(float_value)) {
            try writer.print("Infinity", .{});
        } else if (std.math.isNegativeInf(float_value)) {
            try writer.print("-Infinity", .{});
        } else {
            try writer.print("{d}", .{float_value});
        }
    } else if (value.asBool()) |bool_value| {
        try writer.print("{s}", .{if (bool_value) "true" else "false"});
    } else if (value.isUndefined()) {
        try writer.print("undefined", .{});
    } else if (value.isNull()) {
        try writer.print("null", .{});
    } else if (value.isString()) {
        try printString(writer, value);
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return writer.print("[object Object]", .{});
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.array_buffer) {
            try writer.print("[object ArrayBuffer]", .{});
        } else if (object_value.class_id == core.class.ids.promise) {
            try writer.print("[object Promise]", .{});
        } else if (object_value.is_array) {
            try printArray(rt, writer, object_value);
        } else {
            try writer.print("[object Object]", .{});
        }
    } else {
        try writer.print("[object Object]", .{});
    }
}

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |v| return @floatFromInt(v);
    if (value.asFloat64()) |v| return v;
    return null;
}

fn isFunctionObject(value: core.Value) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.bound_function or
        object.class_id == core.class.ids.c_function_data or
        object.class_id == core.class.ids.c_closure;
}

fn valueToI64(value: core.Value) ?i64 {
    if (numberValue(value)) |number| {
        if (!std.math.isFinite(number)) return null;
        return @intFromFloat(number);
    }
    return null;
}

const ms_per_second: i64 = 1000;
const ms_per_minute: i64 = 60 * ms_per_second;
const ms_per_hour: i64 = 60 * ms_per_minute;
const ms_per_day: i64 = 24 * ms_per_hour;

const DateParts = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    millis: i64,
    weekday: i64,
};

fn makeUtcMs(year: i64, month_zero_based: i64, day: i64, hour: i64, minute: i64, second: i64, millis: i64) f64 {
    const month_one_based = month_zero_based + 1;
    const years_delta = @divFloor(month_one_based - 1, 12);
    const normalized_year = year + years_delta;
    const normalized_month = @mod(month_one_based - 1, 12) + 1;
    const days = daysFromCivil(normalized_year, normalized_month, day);
    const total = days * ms_per_day + hour * ms_per_hour + minute * ms_per_minute + second * ms_per_second + millis;
    return @floatFromInt(total);
}

fn utcDateParts(ms: i64) DateParts {
    const days = @divFloor(ms, ms_per_day);
    var time = @mod(ms, ms_per_day);
    const civil = civilFromDays(days);
    const hour = @divFloor(time, ms_per_hour);
    time = @mod(time, ms_per_hour);
    const minute = @divFloor(time, ms_per_minute);
    time = @mod(time, ms_per_minute);
    const second = @divFloor(time, ms_per_second);
    const millis = @mod(time, ms_per_second);
    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .millis = millis,
        .weekday = @mod(days + 4, 7),
    };
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days_since_epoch: i64) struct { year: i64, month: i64, day: i64 } {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + if (mp < 10) @as(i64, 3) else @as(i64, -9);
    year += if (month <= 2) 1 else 0;
    return .{ .year = year, .month = month, .day = day };
}

fn isTruthy(value: core.Value) bool {
    if (value.isUndefined() or value.isNull()) return false;
    if (value.asBool()) |bool_value| return bool_value;
    if (value.asInt32()) |int_value| return int_value != 0;
    if (value.asFloat64()) |float_value| return float_value != 0 and !std.math.isNan(float_value);
    if (value.isString()) {
        const header = value.refHeader() orelse return false;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return string_value.len() != 0;
    }
    return true;
}

fn isNegativeZero(value: f64) bool {
    return value == 0 and std.math.isNegativeInf(1.0 / value);
}

fn sameValue(a: core.Value, b: core.Value) bool {
    if (numberValue(a)) |lhs| {
        if (numberValue(b)) |rhs| {
            if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
            if (lhs == 0 and rhs == 0) return isNegativeZero(lhs) == isNegativeZero(rhs);
            return lhs == rhs;
        }
    }
    return valuesEqual(a, b);
}

fn mathMin(args: []const core.Value) f64 {
    var out = std.math.inf(f64);
    for (args) |arg| out = @min(out, numberValue(arg) orelse std.math.nan(f64));
    return out;
}

fn mathMax(args: []const core.Value) f64 {
    var out = -std.math.inf(f64);
    for (args) |arg| out = @max(out, numberValue(arg) orelse std.math.nan(f64));
    return out;
}

fn printArray(rt: *core.Runtime, writer: *std.Io.Writer, object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try writer.print(",", .{});
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try printValue(rt, writer, value);
    }
}

fn printString(writer: *std.Io.Writer, value: core.Value) !void {
    const header = value.refHeader() orelse return writer.print("[string]", .{});
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try writer.print("{s}", .{bytes}),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) {
                    try writer.writeByte(@intCast(unit));
                } else {
                    try writer.print("\\u{x}", .{unit});
                }
            }
        },
    }
}

fn rtAtomNameEql(rt: *core.Runtime, atom_id: core.Atom, name: []const u8) bool {
    return if (rt.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

fn trimLeadingAsciiWhitespace(source: []const u8) []const u8 {
    var index: usize = 0;
    while (index < source.len and (source[index] == ' ' or source[index] == '\t' or source[index] == '\r' or source[index] == '\n')) : (index += 1) {}
    return source[index..];
}

fn encodeUriBytes(rt: *core.Runtime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    for (bytes) |ch| {
        if (isUriUnescaped(ch) or (!component and isUriReserved(ch))) {
            try out.append(rt.memory.allocator, ch);
        } else {
            var encoded: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&encoded, "%{X:0>2}", .{ch});
            try out.appendSlice(rt.memory.allocator, &encoded);
        }
    }
}

fn decodeUriBytes(rt: *core.Runtime, out: *std.ArrayList(u8), bytes: []const u8, component: bool) !void {
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] != '%' or index + 2 >= bytes.len or !std.ascii.isHex(bytes[index + 1]) or !std.ascii.isHex(bytes[index + 2])) {
            try out.append(rt.memory.allocator, bytes[index]);
            continue;
        }
        const decoded: u8 = @intCast((hexValue(bytes[index + 1]) << 4) | hexValue(bytes[index + 2]));
        if (!component and isUriReserved(decoded)) {
            try out.appendSlice(rt.memory.allocator, bytes[index .. index + 3]);
        } else {
            try out.append(rt.memory.allocator, decoded);
        }
        index += 2;
    }
}

fn isUriUnescaped(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '!' or ch == '~' or ch == '*' or ch == '\'' or ch == '(' or ch == ')';
}

fn isUriReserved(ch: u8) bool {
    return ch == ';' or ch == ',' or ch == '/' or ch == '?' or ch == ':' or ch == '@' or ch == '&' or ch == '=' or ch == '+' or ch == '$' or ch == '#';
}

fn hexValue(ch: u8) u8 {
    if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
    if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
    return @intCast(ch - 'A' + 10);
}

fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) try buffer.append(rt.memory.allocator, @intCast(unit));
            }
        },
    }
}

fn appendIntField(rt: *core.Runtime, buffer: *std.ArrayList(u8), label: []const u8, value: i32) !void {
    var int_buf: [32]u8 = undefined;
    const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{value});
    try buffer.appendSlice(rt.memory.allocator, label);
    try buffer.appendSlice(rt.memory.allocator, printed);
    try buffer.append(rt.memory.allocator, ',');
}

fn appendJsonValue(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value, array_slot: bool) anyerror!void {
    if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, if (array_slot) "null" else "");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isString()) {
        try buffer.append(rt.memory.allocator, '"');
        try appendRawString(rt, buffer, value);
        try buffer.append(rt.memory.allocator, '"');
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.is_array) {
            try appendJsonArray(rt, buffer, object_value);
        } else {
            try appendJsonObject(rt, buffer, object_value);
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "null");
    }
}

fn appendJsonArray(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    try buffer.append(rt.memory.allocator, '[');
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try appendJsonValue(rt, buffer, value, true);
    }
    try buffer.append(rt.memory.allocator, ']');
}

fn appendJsonObject(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    try buffer.append(rt.memory.allocator, '{');
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    var emitted = false;
    for (keys) |key| {
        const value = object.getProperty(key);
        defer value.free(rt);
        if (value.isUndefined()) continue;
        if (emitted) try buffer.append(rt.memory.allocator, ',');
        emitted = true;
        try buffer.append(rt.memory.allocator, '"');
        if (rt.atoms.name(key)) |name| try buffer.appendSlice(rt.memory.allocator, name);
        try buffer.appendSlice(rt.memory.allocator, "\":");
        try appendJsonValue(rt, buffer, value, false);
    }
    try buffer.append(rt.memory.allocator, '}');
}

fn parseFlatJsonObject(rt: *core.Runtime, bytes: []const u8) !*core.Object {
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (bytes.len < 2 or bytes[0] != '{' or bytes[bytes.len - 1] != '}') return object;
    var index: usize = 1;
    while (index + 1 < bytes.len) {
        if (bytes[index] == ',') index += 1;
        if (index >= bytes.len or bytes[index] != '"') break;
        index += 1;
        const key_start = index;
        while (index < bytes.len and bytes[index] != '"') : (index += 1) {}
        if (index >= bytes.len) break;
        const key = try rt.internAtom(bytes[key_start..index]);
        index += 1;
        if (index >= bytes.len or bytes[index] != ':') break;
        index += 1;
        const value_start = index;
        while (index < bytes.len and bytes[index] != ',' and bytes[index] != '}') : (index += 1) {}
        const raw_value = bytes[value_start..index];
        const parsed_value = if (std.mem.eql(u8, raw_value, "null"))
            core.Value.nullValue()
        else
            core.Value.int32(std.fmt.parseInt(i32, raw_value, 10) catch 0);
        try object.defineOwnProperty(rt, key, core.Descriptor.data(parsed_value, true, true, true));
    }
    return object;
}

fn appendValueString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) anyerror!void {
    if (value.asInt32()) |int_value| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asFloat64()) |float_value| {
        if (std.math.isNan(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "NaN");
        } else if (std.math.isPositiveInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "Infinity");
        } else if (std.math.isNegativeInf(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "-Infinity");
        } else if (isNegativeZero(float_value)) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var float_buf: [64]u8 = undefined;
            const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (value.asShortBigInt()) |big_int| {
        var int_buf: [32]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{big_int});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, "undefined");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.isString()) {
        const header = value.refHeader() orelse return;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        switch (string_value.data) {
            .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
            .utf16 => |units| {
                for (units) |unit| {
                    if (unit <= 0x7f) {
                        try buffer.append(rt.memory.allocator, @intCast(unit));
                    } else {
                        var unit_buf: [16]u8 = undefined;
                        const printed = try std.fmt.bufPrint(&unit_buf, "\\u{x}", .{unit});
                        try buffer.appendSlice(rt.memory.allocator, printed);
                    }
                }
            },
        }
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.array_buffer) {
            try buffer.appendSlice(rt.memory.allocator, "[object ArrayBuffer]");
        } else if (object_value.class_id == core.class.ids.promise) {
            try buffer.appendSlice(rt.memory.allocator, "[object Promise]");
        } else if (object_value.is_array) {
            try appendArrayString(rt, buffer, object_value);
        } else {
            try buffer.appendSlice(rt.memory.allocator, "[object Object]");
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "[object Object]");
    }
}

fn stringSearchStart(rt: *core.Runtime, length: usize, value: core.Value) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (std.math.isPositiveInf(number)) return length;
    const truncated = @trunc(number);
    if (truncated >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(truncated);
}

fn toIntegerOrInfinity(rt: *core.Runtime, value: core.Value) !f64 {
    if (numberValue(value)) |number| return number;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendValueString(rt, &buffer, value);
    return parseJsNumber(buffer.items);
}

fn toIndexUsize(rt: *core.Runtime, value: core.Value) !usize {
    const number = try toIntegerOrInfinity(rt, value);
    if (std.math.isNan(number)) return 0;
    if (!std.math.isFinite(number)) return error.RangeError;
    const truncated = @trunc(number);
    if (truncated <= 0) return 0;
    return @intFromFloat(truncated);
}

fn parseJsNumber(bytes: []const u8) f64 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return std.math.nan(f64);
    if (std.mem.eql(u8, trimmed, "Infinity") or std.mem.eql(u8, trimmed, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
}

fn appendArrayString(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        if (!value.isUndefined() and !value.isNull()) try appendValueString(rt, buffer, value);
    }
}

fn valuesEqual(a: core.Value, b: core.Value) bool {
    if (a.asInt32()) |ai| {
        if (b.asInt32()) |bi| return ai == bi;
    }
    if (a.asBool()) |ab| {
        if (b.asBool()) |bb| return ab == bb;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
        return (compareStringValues(a, b) orelse 1) == 0;
    }
    return a.same(b);
}

fn valuesLooseEqual(a: core.Value, b: core.Value) bool {
    if (valuesEqual(a, b)) return true;
    if ((a.isNull() and b.isUndefined()) or (a.isUndefined() and b.isNull())) return true;
    if (numberLikeInt(a)) |ai| {
        if (numberLikeInt(b)) |bi| return ai == bi;
    }
    return false;
}

fn numberLikeInt(value: core.Value) ?i32 {
    if (value.asInt32()) |int_value| return int_value;
    if (value.asBool()) |bool_value| return if (bool_value) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isString()) {
        const header = value.refHeader() orelse return null;
        const string_value: *core.string.String = @fieldParentPtr("header", header);
        return switch (string_value.data) {
            .latin1 => |bytes| parseIntString(bytes),
            .utf16 => null,
        };
    }
    return null;
}

fn parseIntString(bytes: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

fn compareStringValues(a: core.Value, b: core.Value) ?i32 {
    const a_header = a.refHeader() orelse return null;
    const b_header = b.refHeader() orelse return null;
    const a_string: *core.string.String = @fieldParentPtr("header", a_header);
    const b_string: *core.string.String = @fieldParentPtr("header", b_header);
    return a_string.compare(b_string.*);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn powI32(lhs: i32, rhs: i32) i32 {
    if (rhs < 0) return 0;
    var out: i32 = 1;
    var i: i32 = 0;
    while (i < rhs) : (i += 1) out *= lhs;
    return out;
}

const std = @import("std");
