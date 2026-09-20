//! Identifier, keyword, and atom predicates shared by the parser modules.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const libs_bignum = @import("../libs/bigint.zig");
const tok = root.token;
const diagnostics = root.diagnostics;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const Error = parse_state.Error;
const State = parse_state.State;

pub fn hasKnownBinding(s: *State, atom_id: Atom) bool {
    for (s.curFunc().closure_var) |cv| {
        if (cv.var_name == atom_id) return true;
    }
    // QuickJS keeps top-level declarations in `global_vars` until
    // add_global_variables materializes their closure rows.  Binding
    // queries performed during parsing (notably local-export validation
    // and module redeclaration checks) must therefore consult the
    // declaration table directly rather than relying on parser-created
    // closure placeholders.
    for (s.curFunc().global_vars) |gv| {
        if (gv.var_name == atom_id) return true;
    }
    var scope = s.scope_level;
    while (scope >= 0 and @as(usize, @intCast(scope)) < s.curFunc().scopes.len) {
        var idx = s.curFunc().scopes[@intCast(scope)].first;
        while (idx >= 0 and @as(usize, @intCast(idx)) < s.curFunc().vars.len) {
            const v = s.curFunc().vars[@intCast(idx)];
            if (v.scope_level != scope) break;
            if (v.var_name == atom_id) return true;
            idx = v.scope_next;
        }
        scope = s.curFunc().scopes[@intCast(scope)].parent;
    }
    for (s.curFunc().args) |a| {
        if (a.var_name == atom_id) return true;
    }
    return false;
}

/// A strict assignment whose target is an unresolvable Reference must
/// throw a ReferenceError decided when the LeftHandSideExpression is
/// evaluated, not when the store happens (sec-putvalue: PutValue inspects
/// the Reference Record produced by ResolveBinding, which ran before the
/// RHS). The RHS can create the global property in between —
/// `undeclared = (this.undeclared = 5)` — and a plain `scope_put_var`,
/// whose global lookup runs after the RHS, then stores silently. Emitting
/// the reference form snapshots the unresolved binding before the RHS
/// runs; `resolve_variables` folds it back to a direct store wherever the
/// binding turns out to be statically known.
///
/// Deliberately restricted to the outermost FunctionDef of a plain
/// script. `ensureClosureVar` is a no-op while the parser emits phase-1
/// name+scope bytecode (binding discovery belongs to the topology pass),
/// so `hasKnownBinding` only sees THIS FunctionDef's own tables: inside a
/// nested function it reports "no binding" for every parent-function
/// capture, and in a module or a direct eval the binding can live in the
/// module record or the caller's environment. Only at script top level is
/// "absent from this FunctionDef" the same statement as "unresolvable".
pub inline fn strictUnresolvedAssignmentNeedsReference(s: *State, atom_id: Atom, keep: bool) bool {
    // A compound assignment or an update operator reads the target first,
    // and that read already throws for an unresolvable strict reference.
    if (keep) return false;
    if (!(s.is_strict or s.curFunc().is_strict_mode)) return false;
    if (s.is_eval or s.lex.is_module or s.curFunc().is_module) return false;
    if (s.cur_func_stack.len != 0) return false;
    return !hasKnownBinding(s, atom_id);
}

pub fn argumentsIdentifierIsForbidden(s: *State) bool {
    // QuickJS parses every field initializer in a synthetic method whose
    // FunctionDef has arguments_allowed=false. Both
    // instance and static initializers now use that real function
    // boundary, and arrows inherit its entry contract.
    return !s.curFunc().arguments_allowed;
}

fn tokenStartsPrimaryExpression(k: tok.TokenKind) bool {
    return k == .number or
        k == .string or
        k == .template or
        k == .kw_true or
        k == .kw_false or
        k == .kw_null or
        k == .kw_this or
        k == .kw_super or
        k == .kw_class or
        k == .kw_function or
        k == .ident or
        k == .kw_let or
        k == .kw_yield or
        k == .lparen or
        k == .lbracket or
        k == .lbrace or
        k == .slash or
        k == .div_assign;
}

pub fn tokenStartsYieldExpressionOperand(k: tok.TokenKind) bool {
    return tokenStartsPrimaryExpression(k) and !tokenCanStartSlashRegexp(k);
}

pub fn tokenCanStartSlashRegexp(k: tok.TokenKind) bool {
    return k == .slash or k == .div_assign;
}

/// leftover candidate39 still had a 757 B CurrentContext copy whose extra
/// null/false/true/await/yield checks already live in this walk.
pub noinline fn escapedIdentifierIsReservedWordForBinding(s: *State, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    const name = s.atoms.name(atom_id) orelse return false;
    const strict = s.is_strict or s.curFunc().is_strict_mode;
    return std.mem.eql(u8, name, "null") or
        std.mem.eql(u8, name, "false") or
        std.mem.eql(u8, name, "true") or
        std.mem.eql(u8, name, "if") or
        std.mem.eql(u8, name, "else") or
        std.mem.eql(u8, name, "return") or
        std.mem.eql(u8, name, "var") or
        std.mem.eql(u8, name, "this") or
        std.mem.eql(u8, name, "delete") or
        std.mem.eql(u8, name, "void") or
        std.mem.eql(u8, name, "typeof") or
        std.mem.eql(u8, name, "new") or
        std.mem.eql(u8, name, "in") or
        std.mem.eql(u8, name, "instanceof") or
        std.mem.eql(u8, name, "do") or
        std.mem.eql(u8, name, "while") or
        std.mem.eql(u8, name, "for") or
        std.mem.eql(u8, name, "break") or
        std.mem.eql(u8, name, "continue") or
        std.mem.eql(u8, name, "switch") or
        std.mem.eql(u8, name, "case") or
        std.mem.eql(u8, name, "default") or
        std.mem.eql(u8, name, "throw") or
        std.mem.eql(u8, name, "try") or
        std.mem.eql(u8, name, "catch") or
        std.mem.eql(u8, name, "finally") or
        std.mem.eql(u8, name, "function") or
        std.mem.eql(u8, name, "debugger") or
        std.mem.eql(u8, name, "with") or
        std.mem.eql(u8, name, "class") or
        std.mem.eql(u8, name, "const") or
        std.mem.eql(u8, name, "enum") or
        std.mem.eql(u8, name, "export") or
        std.mem.eql(u8, name, "extends") or
        std.mem.eql(u8, name, "import") or
        std.mem.eql(u8, name, "super") or
        (strict and (std.mem.eql(u8, name, "implements") or
            std.mem.eql(u8, name, "interface") or
            std.mem.eql(u8, name, "let") or
            std.mem.eql(u8, name, "package") or
            std.mem.eql(u8, name, "private") or
            std.mem.eql(u8, name, "protected") or
            std.mem.eql(u8, name, "public") or
            std.mem.eql(u8, name, "static"))) or
        ((s.ctx.in_generator or strict) and std.mem.eql(u8, name, "yield")) or
        ((s.ctx.in_async or s.lex.is_module or s.ctx.in_class_static_block) and std.mem.eql(u8, name, "await"));
}

pub fn escapedIdentifierIsReservedWordForShorthandBinding(s: *State, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    const name = s.atoms.name(atom_id) orelse return false;
    return escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape) or
        std.mem.eql(u8, name, "implements") or
        std.mem.eql(u8, name, "interface") or
        std.mem.eql(u8, name, "let") or
        std.mem.eql(u8, name, "package") or
        std.mem.eql(u8, name, "private") or
        std.mem.eql(u8, name, "protected") or
        std.mem.eql(u8, name, "public") or
        std.mem.eql(u8, name, "static") or
        std.mem.eql(u8, name, "yield");
}

/// Same reserved set as `ForBinding`. The previous extra keyword checks
/// were already covered by that walk.
pub inline fn escapedIdentifierIsReservedWordForCurrentContext(s: *State, atom_id: Atom, has_escape: bool) bool {
    return escapedIdentifierIsReservedWordForBinding(s, atom_id, has_escape);
}

pub fn isInvalidStrictFunctionBindingName(s: *State, atom_id: Atom) bool {
    _ = s;
    return atom_id == atom_module.ids.eval_ or atom_id == atom_module.ids.arguments;
}

pub fn recordInvalidStrictParameterName(s: *State, first: *?diagnostics.Position, atom_id: Atom) void {
    if (first.* == null and isInvalidStrictFunctionBindingName(s, atom_id)) {
        first.* = s.currentDiagnosticPosition();
    }
}

pub fn rejectInvalidStrictParameterName(s: *State, first: ?diagnostics.Position) Error!void {
    const position = first orelse return;
    return s.failWithMessage(position, "invalid binding name in strict parameter list");
}

pub fn canUseAwaitAsIdentifier(s: *State) bool {
    return !s.ctx.in_async and !s.lex.is_module and !s.ctx.in_class_static_block;
}

pub fn isIdentifierLikeToken(s: *State) bool {
    return s.peekKind() == .ident or
        (s.peekKind() == .kw_await and canUseAwaitAsIdentifier(s)) or
        (s.peekKind() == .kw_yield and !s.ctx.in_generator and !(s.is_strict or s.curFunc().is_strict_mode)) or
        isSloppyFutureReservedBindingToken(s) or
        (!(s.is_strict or s.curFunc().is_strict_mode) and
            (s.peekKind() == .kw_static or s.peekKind() == .kw_let));
}

pub fn isSloppyFutureReservedBindingToken(s: *State) bool {
    return !(s.is_strict or s.curFunc().is_strict_mode) and isSloppyFutureReservedToken(s.peekKind());
}

pub fn isSloppyFutureReservedToken(kind: tok.TokenKind) bool {
    return switch (kind) {
        .kw_implements,
        .kw_interface,
        .kw_package,
        .kw_private,
        .kw_protected,
        .kw_public,
        => true,
        else => false,
    };
}

pub fn tokenCanStartExpression(kind: tok.TokenKind) bool {
    return kind == .ident or
        kind == .kw_await or
        kind == .kw_yield or
        kind == .number or
        kind == .string or
        kind == .kw_true or
        kind == .kw_false or
        kind == .kw_null or
        kind == .kw_this or
        kind == .kw_function or
        kind == .kw_class or
        kind == .lparen or
        kind == .lbracket or
        kind == .lbrace;
}

pub fn identifierLikeAtom(s: *State) Atom {
    // Borrowed id: interning is rooted by the enclosing CompileAtomScope, so
    // the value stays valid past `advance()` without any retain.
    return if (s.peekKind() == .ident) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
}

pub fn identifierLikeHasInvalidEscapeForBinding(s: *State) bool {
    return s.peekKind() == .ident and
        escapedIdentifierIsReservedWordForBinding(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape);
}

pub fn atomNameEquals(s: *State, atom_id: Atom, name: []const u8) bool {
    return if (s.atoms.name(atom_id)) |atom_name| std.mem.eql(u8, atom_name, name) else false;
}

fn atomsNameEqual(s: *State, left: Atom, right: Atom) bool {
    if (left == right) return true;
    const left_name = s.atoms.name(left) orelse return false;
    const right_name = s.atoms.name(right) orelse return false;
    return std.mem.eql(u8, left_name, right_name);
}

pub fn evalAnnexBBlockedFunctionName(s: *State, atom_id: Atom) bool {
    for (s.eval_annex_b_blocked_function_names) |blocked| {
        if (atomsNameEqual(s, atom_id, blocked)) return true;
    }
    return false;
}

pub fn atomNameIsPrivate(s: *State, atom_id: Atom) bool {
    return s.atoms.kind(atom_id) == .private;
}

pub fn formatBigIntPropertyName(s: *State, text: []const u8) Error![]const u8 {
    const parse_text = if (std.mem.indexOfScalar(u8, text, '_')) |_| blk: {
        var normalized = std.ArrayList(u8).empty;
        errdefer normalized.deinit(s.memory.allocator);
        for (text) |ch| {
            if (ch != '_') try normalized.append(s.memory.allocator, ch);
        }
        break :blk try normalized.toOwnedSlice(s.memory.allocator);
    } else text;
    defer if (parse_text.ptr != text.ptr) s.memory.allocator.free(parse_text);

    var parsed = libs_bignum.parseAutoAlloc(s.memory.allocator, parse_text) catch return Error.InvalidNumberLiteral;
    defer parsed.deinit();
    return parsed.formatBase10Alloc(s.memory.allocator) catch |err| switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        // Base 10 is always a valid radix.
        error.InvalidRadix => Error.ParserInvariant,
    };
}

pub fn numberIsExactI32(value: f64) bool {
    if (std.math.isNan(value) or std.math.isInf(value)) return false;
    if (value < @as(f64, std.math.minInt(i32)) or value > @as(f64, std.math.maxInt(i32))) return false;
    const truncated: f64 = @floatFromInt(@as(i32, @intFromFloat(value)));
    return truncated == value;
}
