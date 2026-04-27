const memory = @import("memory.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;

pub const Atom = u32;

pub const null_atom: Atom = 0;
pub const tagged_int_bit: Atom = 1 << 31;
pub const max_int_atom: Atom = tagged_int_bit - 1;

pub const AtomKind = enum {
    string,
    symbol,
    private,
};

pub const PredefinedAtom = struct {
    id: Atom,
    name: []const u8,
    kind: AtomKind = .string,
};

pub const ids = struct {
    pub const null_: Atom = 1;
    pub const false_: Atom = 2;
    pub const true_: Atom = 3;
    pub const if_: Atom = 4;
    pub const super: Atom = 36;
    pub const yield: Atom = 45;
    pub const await: Atom = 46;
    pub const empty_string: Atom = 47;
    pub const length: Atom = 50;
    pub const name: Atom = 55;
    pub const prototype: Atom = 60;
    pub const constructor: Atom = 61;
    pub const undefined_: Atom = 70;
    pub const Object: Atom = 151;
    pub const Array: Atom = 152;
    pub const Error: Atom = 153;
    pub const Function: Atom = 162;
    pub const Map: Atom = 184;
    pub const Set: Atom = 185;
    pub const WeakMap: Atom = 186;
    pub const WeakSet: Atom = 187;
    pub const Private_brand: Atom = 216;
    pub const Symbol_toPrimitive: Atom = 217;
    pub const Symbol_iterator: Atom = 218;
    pub const Symbol_asyncIterator: Atom = 229;
};

pub const last_keyword = ids.await;
pub const last_strict_keyword = ids.yield;
pub const predefined_count = predefined_atoms.len;
pub const first_dynamic_atom = predefined_count + 1;

pub const predefined_atoms = [_]PredefinedAtom{
    .{ .id = 1, .name = "null" },
    .{ .id = 2, .name = "false" },
    .{ .id = 3, .name = "true" },
    .{ .id = 4, .name = "if" },
    .{ .id = 5, .name = "else" },
    .{ .id = 6, .name = "return" },
    .{ .id = 7, .name = "var" },
    .{ .id = 8, .name = "this" },
    .{ .id = 9, .name = "delete" },
    .{ .id = 10, .name = "void" },
    .{ .id = 11, .name = "typeof" },
    .{ .id = 12, .name = "new" },
    .{ .id = 13, .name = "in" },
    .{ .id = 14, .name = "instanceof" },
    .{ .id = 15, .name = "do" },
    .{ .id = 16, .name = "while" },
    .{ .id = 17, .name = "for" },
    .{ .id = 18, .name = "break" },
    .{ .id = 19, .name = "continue" },
    .{ .id = 20, .name = "switch" },
    .{ .id = 21, .name = "case" },
    .{ .id = 22, .name = "default" },
    .{ .id = 23, .name = "throw" },
    .{ .id = 24, .name = "try" },
    .{ .id = 25, .name = "catch" },
    .{ .id = 26, .name = "finally" },
    .{ .id = 27, .name = "function" },
    .{ .id = 28, .name = "debugger" },
    .{ .id = 29, .name = "with" },
    .{ .id = 30, .name = "class" },
    .{ .id = 31, .name = "const" },
    .{ .id = 32, .name = "enum" },
    .{ .id = 33, .name = "export" },
    .{ .id = 34, .name = "extends" },
    .{ .id = 35, .name = "import" },
    .{ .id = 36, .name = "super" },
    .{ .id = 37, .name = "implements" },
    .{ .id = 38, .name = "interface" },
    .{ .id = 39, .name = "let" },
    .{ .id = 40, .name = "package" },
    .{ .id = 41, .name = "private" },
    .{ .id = 42, .name = "protected" },
    .{ .id = 43, .name = "public" },
    .{ .id = 44, .name = "static" },
    .{ .id = 45, .name = "yield" },
    .{ .id = 46, .name = "await" },
    .{ .id = 47, .name = "" },
    .{ .id = 48, .name = "keys" },
    .{ .id = 49, .name = "size" },
    .{ .id = 50, .name = "length" },
    .{ .id = 51, .name = "message" },
    .{ .id = 52, .name = "cause" },
    .{ .id = 53, .name = "errors" },
    .{ .id = 54, .name = "stack" },
    .{ .id = 55, .name = "name" },
    .{ .id = 56, .name = "toString" },
    .{ .id = 57, .name = "toLocaleString" },
    .{ .id = 58, .name = "valueOf" },
    .{ .id = 59, .name = "eval" },
    .{ .id = 60, .name = "prototype" },
    .{ .id = 61, .name = "constructor" },
    .{ .id = 62, .name = "configurable" },
    .{ .id = 63, .name = "writable" },
    .{ .id = 64, .name = "enumerable" },
    .{ .id = 65, .name = "value" },
    .{ .id = 66, .name = "get" },
    .{ .id = 67, .name = "set" },
    .{ .id = 68, .name = "of" },
    .{ .id = 69, .name = "__proto__" },
    .{ .id = 70, .name = "undefined" },
    .{ .id = 71, .name = "number" },
    .{ .id = 72, .name = "boolean" },
    .{ .id = 73, .name = "string" },
    .{ .id = 74, .name = "object" },
    .{ .id = 75, .name = "symbol" },
    .{ .id = 76, .name = "integer" },
    .{ .id = 77, .name = "unknown" },
    .{ .id = 78, .name = "arguments" },
    .{ .id = 79, .name = "callee" },
    .{ .id = 80, .name = "caller" },
    .{ .id = 81, .name = "<eval>" },
    .{ .id = 82, .name = "<ret>" },
    .{ .id = 83, .name = "<var>" },
    .{ .id = 84, .name = "<arg_var>" },
    .{ .id = 85, .name = "<with>" },
    .{ .id = 86, .name = "lastIndex" },
    .{ .id = 87, .name = "target" },
    .{ .id = 88, .name = "index" },
    .{ .id = 89, .name = "input" },
    .{ .id = 90, .name = "defineProperties" },
    .{ .id = 91, .name = "apply" },
    .{ .id = 92, .name = "join" },
    .{ .id = 93, .name = "concat" },
    .{ .id = 94, .name = "split" },
    .{ .id = 95, .name = "construct" },
    .{ .id = 96, .name = "getPrototypeOf" },
    .{ .id = 97, .name = "setPrototypeOf" },
    .{ .id = 98, .name = "isExtensible" },
    .{ .id = 99, .name = "preventExtensions" },
    .{ .id = 100, .name = "has" },
    .{ .id = 101, .name = "deleteProperty" },
    .{ .id = 102, .name = "defineProperty" },
    .{ .id = 103, .name = "getOwnPropertyDescriptor" },
    .{ .id = 104, .name = "ownKeys" },
    .{ .id = 105, .name = "add" },
    .{ .id = 106, .name = "done" },
    .{ .id = 107, .name = "next" },
    .{ .id = 108, .name = "values" },
    .{ .id = 109, .name = "source" },
    .{ .id = 110, .name = "flags" },
    .{ .id = 111, .name = "global" },
    .{ .id = 112, .name = "unicode" },
    .{ .id = 113, .name = "raw" },
    .{ .id = 114, .name = "rawJSON" },
    .{ .id = 115, .name = "new.target" },
    .{ .id = 116, .name = "this.active_func" },
    .{ .id = 117, .name = "<home_object>" },
    .{ .id = 118, .name = "<computed_field>" },
    .{ .id = 119, .name = "<static_computed_field>" },
    .{ .id = 120, .name = "<class_fields_init>" },
    .{ .id = 121, .name = "<brand>" },
    .{ .id = 122, .name = "#constructor" },
    .{ .id = 123, .name = "as" },
    .{ .id = 124, .name = "from" },
    .{ .id = 125, .name = "fromAsync" },
    .{ .id = 126, .name = "meta" },
    .{ .id = 127, .name = "*default*" },
    .{ .id = 128, .name = "*" },
    .{ .id = 129, .name = "Module" },
    .{ .id = 130, .name = "then" },
    .{ .id = 131, .name = "resolve" },
    .{ .id = 132, .name = "reject" },
    .{ .id = 133, .name = "promise" },
    .{ .id = 134, .name = "proxy" },
    .{ .id = 135, .name = "revoke" },
    .{ .id = 136, .name = "async" },
    .{ .id = 137, .name = "exec" },
    .{ .id = 138, .name = "groups" },
    .{ .id = 139, .name = "indices" },
    .{ .id = 140, .name = "status" },
    .{ .id = 141, .name = "reason" },
    .{ .id = 142, .name = "globalThis" },
    .{ .id = 143, .name = "bigint" },
    .{ .id = 144, .name = "not-equal" },
    .{ .id = 145, .name = "timed-out" },
    .{ .id = 146, .name = "ok" },
    .{ .id = 147, .name = "toJSON" },
    .{ .id = 148, .name = "maxByteLength" },
    .{ .id = 149, .name = "zip" },
    .{ .id = 150, .name = "zipKeyed" },
    .{ .id = 151, .name = "Object" },
    .{ .id = 152, .name = "Array" },
    .{ .id = 153, .name = "Error" },
    .{ .id = 154, .name = "Number" },
    .{ .id = 155, .name = "String" },
    .{ .id = 156, .name = "Boolean" },
    .{ .id = 157, .name = "Symbol" },
    .{ .id = 158, .name = "Arguments" },
    .{ .id = 159, .name = "Math" },
    .{ .id = 160, .name = "JSON" },
    .{ .id = 161, .name = "Date" },
    .{ .id = 162, .name = "Function" },
    .{ .id = 163, .name = "GeneratorFunction" },
    .{ .id = 164, .name = "ForInIterator" },
    .{ .id = 165, .name = "RegExp" },
    .{ .id = 166, .name = "ArrayBuffer" },
    .{ .id = 167, .name = "SharedArrayBuffer" },
    .{ .id = 168, .name = "Uint8ClampedArray" },
    .{ .id = 169, .name = "Int8Array" },
    .{ .id = 170, .name = "Uint8Array" },
    .{ .id = 171, .name = "Int16Array" },
    .{ .id = 172, .name = "Uint16Array" },
    .{ .id = 173, .name = "Int32Array" },
    .{ .id = 174, .name = "Uint32Array" },
    .{ .id = 175, .name = "BigInt64Array" },
    .{ .id = 176, .name = "BigUint64Array" },
    .{ .id = 177, .name = "Float16Array" },
    .{ .id = 178, .name = "Float32Array" },
    .{ .id = 179, .name = "Float64Array" },
    .{ .id = 180, .name = "DataView" },
    .{ .id = 181, .name = "BigInt" },
    .{ .id = 182, .name = "WeakRef" },
    .{ .id = 183, .name = "FinalizationRegistry" },
    .{ .id = 184, .name = "Map" },
    .{ .id = 185, .name = "Set" },
    .{ .id = 186, .name = "WeakMap" },
    .{ .id = 187, .name = "WeakSet" },
    .{ .id = 188, .name = "Iterator" },
    .{ .id = 189, .name = "Iterator Concat" },
    .{ .id = 190, .name = "Iterator Helper" },
    .{ .id = 191, .name = "Iterator Wrap" },
    .{ .id = 192, .name = "Map Iterator" },
    .{ .id = 193, .name = "Set Iterator" },
    .{ .id = 194, .name = "Array Iterator" },
    .{ .id = 195, .name = "String Iterator" },
    .{ .id = 196, .name = "RegExp String Iterator" },
    .{ .id = 197, .name = "Generator" },
    .{ .id = 198, .name = "Proxy" },
    .{ .id = 199, .name = "Promise" },
    .{ .id = 200, .name = "PromiseResolveFunction" },
    .{ .id = 201, .name = "PromiseRejectFunction" },
    .{ .id = 202, .name = "AsyncFunction" },
    .{ .id = 203, .name = "AsyncFunctionResolve" },
    .{ .id = 204, .name = "AsyncFunctionReject" },
    .{ .id = 205, .name = "AsyncGeneratorFunction" },
    .{ .id = 206, .name = "AsyncGenerator" },
    .{ .id = 207, .name = "EvalError" },
    .{ .id = 208, .name = "RangeError" },
    .{ .id = 209, .name = "ReferenceError" },
    .{ .id = 210, .name = "SyntaxError" },
    .{ .id = 211, .name = "TypeError" },
    .{ .id = 212, .name = "URIError" },
    .{ .id = 213, .name = "InternalError" },
    .{ .id = 214, .name = "DOMException" },
    .{ .id = 215, .name = "CallSite" },
    .{ .id = 216, .name = "<brand>", .kind = .private },
    .{ .id = 217, .name = "Symbol.toPrimitive", .kind = .symbol },
    .{ .id = 218, .name = "Symbol.iterator", .kind = .symbol },
    .{ .id = 219, .name = "Symbol.match", .kind = .symbol },
    .{ .id = 220, .name = "Symbol.matchAll", .kind = .symbol },
    .{ .id = 221, .name = "Symbol.replace", .kind = .symbol },
    .{ .id = 222, .name = "Symbol.search", .kind = .symbol },
    .{ .id = 223, .name = "Symbol.split", .kind = .symbol },
    .{ .id = 224, .name = "Symbol.toStringTag", .kind = .symbol },
    .{ .id = 225, .name = "Symbol.isConcatSpreadable", .kind = .symbol },
    .{ .id = 226, .name = "Symbol.hasInstance", .kind = .symbol },
    .{ .id = 227, .name = "Symbol.species", .kind = .symbol },
    .{ .id = 228, .name = "Symbol.unscopables", .kind = .symbol },
    .{ .id = 229, .name = "Symbol.asyncIterator", .kind = .symbol },
};

pub const DynamicAtom = struct {
    id: Atom,
    bytes: []u8,
    hash: u32,
    kind: AtomKind,
    ref_count: usize,

    pub fn isLive(self: DynamicAtom) bool {
        return self.ref_count != 0;
    }
};

pub const AtomTable = struct {
    memory: *memory.MemoryAccount,
    entries: []DynamicAtom = &.{},
    next_id: Atom = first_dynamic_atom,

    pub fn init(account: *memory.MemoryAccount) AtomTable {
        return .{ .memory = account };
    }

    pub fn deinit(self: *AtomTable) void {
        for (self.entries) |entry| {
            if (entry.bytes.len != 0) self.memory.free(u8, entry.bytes);
        }
        if (self.entries.len != 0) self.memory.free(DynamicAtom, self.entries);
        self.* = .{ .memory = self.memory };
    }

    pub fn internString(self: *AtomTable, bytes: []const u8) !Atom {
        if (predefinedId(bytes, .string)) |id| return id;
        if (parseArrayIndex(bytes)) |n| return atomFromUInt32(n);
        return self.internDynamic(bytes, .string);
    }

    pub fn newSymbol(self: *AtomTable, description: []const u8, atom_kind: AtomKind) !Atom {
        std.debug.assert(atom_kind == .symbol or atom_kind == .private);
        return self.internDynamic(description, atom_kind);
    }

    pub fn dup(self: *AtomTable, atom: Atom) Atom {
        if (isConst(atom) or isTaggedInt(atom)) return atom;
        if (self.findDynamic(atom)) |entry| {
            std.debug.assert(entry.isLive());
            entry.ref_count += 1;
        }
        return atom;
    }

    pub fn free(self: *AtomTable, atom: Atom) void {
        if (isConst(atom) or isTaggedInt(atom)) return;
        const entry = self.findDynamic(atom) orelse return;
        std.debug.assert(entry.ref_count > 0);
        entry.ref_count -= 1;
        if (entry.ref_count == 0) {
            self.memory.free(u8, entry.bytes);
            entry.bytes = &.{};
        }
    }

    pub fn name(self: *const AtomTable, atom: Atom) ?[]const u8 {
        if (atom == null_atom) return null;
        if (isTaggedInt(atom)) return null;
        if (predefinedById(atom)) |entry| return entry.name;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.isLive()) return entry.bytes;
        }
        return null;
    }

    pub fn kind(self: *const AtomTable, atom: Atom) ?AtomKind {
        if (atom == null_atom) return null;
        if (isTaggedInt(atom)) return .string;
        if (predefinedById(atom)) |entry| return entry.kind;
        if (self.findDynamicConst(atom)) |entry| {
            if (entry.isLive()) return entry.kind;
        }
        return null;
    }

    pub fn toStringValue(self: *const AtomTable, rt: anytype, atom_id: Atom) !Value {
        if (isTaggedInt(atom_id)) {
            var buf: [10]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}", .{atomToUInt32(atom_id)});
            const s = try string.String.createAscii(rt, text);
            return s.value();
        }
        const text = self.name(atom_id) orelse return Value.undefinedValue();
        const s = try string.String.createUtf8(rt, text);
        return s.value();
    }

    fn internDynamic(self: *AtomTable, bytes: []const u8, atom_kind: AtomKind) !Atom {
        if (atom_kind == .string) {
            for (self.entries) |*entry| {
                if (entry.isLive() and entry.kind == .string and std.mem.eql(u8, entry.bytes, bytes)) {
                    entry.ref_count += 1;
                    return entry.id;
                }
            }
        }

        const owned = try self.memory.alloc(u8, bytes.len);
        errdefer self.memory.free(u8, owned);
        @memcpy(owned, bytes);

        const id = self.next_id;
        self.next_id += 1;
        try self.append(.{ .id = id, .bytes = owned, .hash = string.hashBytes(bytes), .kind = atom_kind, .ref_count = 1 });
        return id;
    }

    fn append(self: *AtomTable, entry: DynamicAtom) !void {
        const next = try self.memory.alloc(DynamicAtom, self.entries.len + 1);
        errdefer self.memory.free(DynamicAtom, next);
        @memcpy(next[0..self.entries.len], self.entries);
        next[self.entries.len] = entry;
        if (self.entries.len != 0) self.memory.free(DynamicAtom, self.entries);
        self.entries = next;
    }

    fn findDynamic(self: *AtomTable, atom: Atom) ?*DynamicAtom {
        for (self.entries) |*entry| {
            if (entry.id == atom) return entry;
        }
        return null;
    }

    fn findDynamicConst(self: *const AtomTable, atom: Atom) ?*const DynamicAtom {
        for (self.entries) |*entry| {
            if (entry.id == atom) return entry;
        }
        return null;
    }
};

pub fn isConst(atom: Atom) bool {
    return atom < first_dynamic_atom;
}

pub fn isTaggedInt(atom: Atom) bool {
    return (atom & tagged_int_bit) != 0;
}

pub fn atomFromUInt32(n: u32) Atom {
    std.debug.assert(n <= max_int_atom);
    return n | tagged_int_bit;
}

pub fn atomToUInt32(atom: Atom) u32 {
    std.debug.assert(isTaggedInt(atom));
    return atom & ~tagged_int_bit;
}

pub fn predefinedById(id: Atom) ?PredefinedAtom {
    if (id == null_atom or id >= first_dynamic_atom) return null;
    return predefined_atoms[id - 1];
}

pub fn predefinedId(bytes: []const u8, kind: AtomKind) ?Atom {
    @setEvalBranchQuota(30000);
    for (predefined_atoms) |entry| {
        if (entry.kind == kind and std.mem.eql(u8, entry.name, bytes)) return entry.id;
    }
    return null;
}

fn parseArrayIndex(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;
    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_int_atom) return null;
    }
    return @intCast(n);
}

const std = @import("std");
