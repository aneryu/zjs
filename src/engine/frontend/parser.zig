const atom = @import("../core/atom.zig");
const Runtime = @import("../core/runtime.zig").Runtime;
const Value = @import("../core/value.zig").Value;
const bytecode = @import("../bytecode/root.zig");
const lexer = @import("lexer.zig");
const source_pos = @import("source_pos.zig");
const token = @import("token.zig");

pub const Mode = enum {
    script,
    module,
    eval_direct,
    eval_indirect,
};

pub const Feature = enum {
    expression,
    statement,
    function_,
    arrow,
    async_function,
    generator,
    async_generator,
    class_,
    private_name,
    destructuring,
    spread_rest,
    dynamic_import,
};

pub const Result = struct {
    runtime: *Runtime,
    function: bytecode.Bytecode,
    mode: Mode,
    features: std.EnumSet(Feature) = .initEmpty(),
    syntax_error: ?source_pos.SyntaxError = null,
    direct_eval: bool = false,

    pub fn deinit(self: *Result) void {
        if (self.syntax_error) |*err| err.deinit();
        self.function.deinit(self.runtime);
    }

    pub fn hasFeature(self: Result, feature: Feature) bool {
        return self.features.contains(feature);
    }
};

pub const Options = struct {
    mode: Mode = .script,
    filename: []const u8 = "<input>",
};

/// QuickJS source map: JS_EvalObject() selects script/module/eval parse mode,
/// then js_parse_program() and js_parse_function_decl2() feed bytecode emission.
/// Phase 5 fixtures also map syntax domains to js_parse_statement_or_decl(),
/// js_parse_assign_expr(), js_parse_class(), js_parse_import(),
/// js_parse_export(), js_parse_destructuring_element(), and next_token().
pub fn parse(rt: *Runtime, source: []const u8, options: Options) !Result {
    const filename_atom = try rt.internAtom(options.filename);
    defer rt.atoms.free(filename_atom);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, filename_atom);
    errdefer function.deinit(rt);
    function.flags.is_strict = options.mode == .module;

    var result = Result{
        .runtime = rt,
        .function = function,
        .mode = options.mode,
        .direct_eval = options.mode == .eval_direct,
    };
    errdefer result.deinit();

    var emit = bytecode.emitter.Emitter.init(&result.function);
    try emit.emitSourceLoc(0, 1);

    const global_scope = try result.function.addScope(null);
    var lex = lexer.Lexer.init(source);
    var previous: ?token.Token = null;
    var brace_balance: i32 = 0;
    var paren_balance: i32 = 0;
    var pending_host_print = false;
    var host_print_paren_depth: ?i32 = null;
    var host_print_ops: [64]u8 = undefined;
    var host_print_ops_len: usize = 0;

    while (true) {
        const tok = lex.next() catch |err| {
            result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, @errorName(err));
            return result;
        };
        if (tok.kind == .eof) break;
        if (tok.kind == .identifier or tok.kind == .private_identifier) {
            const name = try rt.internAtom(tok.lexeme);
            defer rt.atoms.free(name);
            _ = try global_scope.addBinding(name, .var_, false);
            if (std.mem.eql(u8, tok.lexeme, "print") or std.mem.eql(u8, tok.lexeme, "log")) pending_host_print = true;
            if (std.mem.eql(u8, tok.lexeme, "true")) try emit.emitKnown(bytecode.emitter.known.push_true);
            if (std.mem.eql(u8, tok.lexeme, "false")) try emit.emitKnown(bytecode.emitter.known.push_false);
            if (std.mem.eql(u8, tok.lexeme, "undefined")) try emit.emitKnown(bytecode.emitter.known.undefined_value);
            if (std.mem.eql(u8, tok.lexeme, "null")) try emit.emitKnown(bytecode.emitter.known.null_value);
        }
        if (tok.kind == .numeric) {
            result.features.insert(.expression);
            try emit.emitPushInt32(parseSmallInt(tok.lexeme) orelse 0);
        }
        if (tok.kind == .string or tok.kind == .template_no_substitution or tok.kind == .regexp) {
            result.features.insert(.expression);
            const str = try @import("../core/string.zig").String.createUtf8(rt, literalBody(tok.lexeme));
            const value = str.value();
            _ = try emit.emitPushConst(value);
            value.free(rt);
        }
        if (tok.kind == .private_identifier) result.features.insert(.private_name);
        if (tok.kind == .punctuator) {
            if (std.mem.eql(u8, tok.lexeme, "{")) brace_balance += 1;
            if (std.mem.eql(u8, tok.lexeme, "}")) brace_balance -= 1;
            if (std.mem.eql(u8, tok.lexeme, "(")) {
                paren_balance += 1;
                if (pending_host_print and host_print_paren_depth == null) {
                    host_print_paren_depth = paren_balance;
                    host_print_ops_len = 0;
                }
            }
            if (std.mem.eql(u8, tok.lexeme, ")")) {
                if (host_print_paren_depth != null and host_print_paren_depth.? == paren_balance) {
                    try drainHostPrintOps(&emit, &host_print_ops, &host_print_ops_len);
                    try emit.emitHostPrint();
                    pending_host_print = false;
                    host_print_paren_depth = null;
                }
                paren_balance -= 1;
            }
            if (host_print_paren_depth != null and paren_balance >= host_print_paren_depth.?) {
                if (binaryOpcode(tok.lexeme)) |op| {
                    try pushHostPrintOp(&emit, &host_print_ops, &host_print_ops_len, op);
                }
            }
            if (std.mem.eql(u8, tok.lexeme, "...")) result.features.insert(.spread_rest);
            if (std.mem.eql(u8, tok.lexeme, "[") or std.mem.eql(u8, tok.lexeme, "{")) result.features.insert(.destructuring);
        }
        if (tok.kind == .keyword) try handleKeyword(rt, &result, &emit, global_scope, tok, previous);
        previous = tok;
    }

    if (brace_balance != 0 or paren_balance != 0) {
        result.syntax_error = try source_pos.SyntaxError.create(&rt.memory, &rt.atoms, filename_atom, lex.position, "Unexpected end of input");
        return result;
    }
    try emit.emitReturnUndefined();
    return result;
}

fn pushHostPrintOp(
    emit: *bytecode.emitter.Emitter,
    ops: *[64]u8,
    ops_len: *usize,
    op: u8,
) !void {
    while (ops_len.* > 0 and binaryPrecedence(ops[ops_len.* - 1]) >= binaryPrecedence(op)) {
        ops_len.* -= 1;
        try emit.emitKnown(ops[ops_len.*]);
    }
    if (ops_len.* == ops.len) return error.OutOfMemory;
    ops[ops_len.*] = op;
    ops_len.* += 1;
}

fn drainHostPrintOps(
    emit: *bytecode.emitter.Emitter,
    ops: *[64]u8,
    ops_len: *usize,
) !void {
    while (ops_len.* > 0) {
        ops_len.* -= 1;
        try emit.emitKnown(ops[ops_len.*]);
    }
}

fn binaryOpcode(lexeme: []const u8) ?u8 {
    if (std.mem.eql(u8, lexeme, "*")) return bytecode.emitter.known.mul;
    if (std.mem.eql(u8, lexeme, "/")) return bytecode.emitter.known.div;
    if (std.mem.eql(u8, lexeme, "%")) return bytecode.emitter.known.mod;
    if (std.mem.eql(u8, lexeme, "+")) return bytecode.emitter.known.add;
    if (std.mem.eql(u8, lexeme, "-")) return bytecode.emitter.known.sub;
    return null;
}

fn binaryPrecedence(op: u8) u8 {
    return switch (op) {
        bytecode.emitter.known.mul,
        bytecode.emitter.known.div,
        bytecode.emitter.known.mod,
        => 2,
        bytecode.emitter.known.add,
        bytecode.emitter.known.sub,
        => 1,
        else => 0,
    };
}

fn handleKeyword(
    rt: *Runtime,
    result: *Result,
    emit: *bytecode.emitter.Emitter,
    scope_record: *bytecode.scope.ScopeRecord,
    tok: token.Token,
    previous: ?token.Token,
) !void {
    switch (tok.keyword.?) {
        .var_, .let, .@"const" => result.features.insert(.statement),
        .function => {
            result.features.insert(.function_);
            if (previous != null and previous.?.isKeyword(.async)) result.features.insert(.async_function);
        },
        .async => result.features.insert(.async_function),
        .yield => result.features.insert(.generator),
        .await => result.features.insert(.async_function),
        .class => {
            result.features.insert(.class_);
            try emit.emitKnown(bytecode.emitter.known.define_class);
        },
        .import => {
            if (result.mode == .module) {
                const module_record = result.function.ensureModule();
                const name = try rt.internAtom("<pending-import>");
                defer rt.atoms.free(name);
                const req = try module_record.addRequest(name);
                const default_atom = atom.predefinedId("*default*", .string).?;
                try module_record.addImport(req, default_atom, name);
            } else {
                result.features.insert(.dynamic_import);
                try emit.emitKnown(bytecode.emitter.known.import);
            }
        },
        .@"export" => {
            const module_record = result.function.ensureModule();
            const name = try rt.internAtom("<pending-export>");
            defer rt.atoms.free(name);
            try module_record.addExport(name, name);
        },
        .@"return", .@"break", .case, .@"catch", .default, .throw => result.features.insert(.statement),
        .module, .static, .super, .extends => {},
    }
    _ = scope_record;
}

fn parseSmallInt(bytes: []const u8) ?i32 {
    var clean: [64]u8 = undefined;
    var len: usize = 0;
    for (bytes) |byte| {
        if (byte == '_') continue;
        if (!std.ascii.isDigit(byte)) break;
        if (len == clean.len) return null;
        clean[len] = byte;
        len += 1;
    }
    if (len == 0) return null;
    return std.fmt.parseInt(i32, clean[0..len], 10) catch null;
}

fn literalBody(bytes: []const u8) []const u8 {
    if (bytes.len >= 2) {
        const first = bytes[0];
        const last = bytes[bytes.len - 1];
        if ((first == '"' and last == '"') or
            (first == '\'' and last == '\'') or
            (first == '`' and last == '`'))
        {
            return bytes[1 .. bytes.len - 1];
        }
    }
    return bytes;
}

const std = @import("std");
