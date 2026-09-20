//! Classes: heritage, elements, private names, field initializers, the class tail lowering.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const function_def_mod = bytecode.function_def;
const opcode = bytecode.opcode;
const tok = root.token;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const closure = @import("closure.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const atom_this = parse_state.atom_this;
const atom_class_fields_init = parse_state.atom_class_fields_init;
const FunctionSourceStart = parse_state.FunctionSourceStart;
const Error = parse_state.Error;
const ParseFlags = parse_state.ParseFlags;
const ClassPrivateElementKind = parse_state.ClassPrivateElementKind;
const ClassPrivateElement = parse_state.ClassPrivateElement;
const ParseFunctionKind = parse_state.ParseFunctionKind;
const State = parse_state.State;
const Emitter = emitter.Emitter;

/// Parse class heritage (extends clause)
/// Mirrors `js_parse_class_extends` in quickjs.c
fn parseClassHeritage(s: *State) Error!void {
    if (s.peekKind() == .kw_extends) {
        try s.advance();
        // ClassHeritage is `extends LeftHandSideExpression`, not a full
        // assignment expression; arrow expressions are rejected here.
        if ((try lookahead.checkArrowHead(s, false)) or
            (s.isAsyncIdentifier() and (try lookahead.checkAsyncArrowHeadAfterAsync(s, false))))
        {
            return s.failWithMessage(null, "class heritage must be a left-hand-side expression");
        }
        try expressions.parseLhsExpr(s, ParseFlags.default);
        // TypeScript `extends B<T>`.
        if (s.peekKind() == .lt and !s.gotLineTerminator()) try typescript.tsParseTypeArguments(s);
    }
    if (s.peekKind() == .kw_implements) {
        // TypeScript `implements I<T>, J`.
        try s.advance();
        while (true) {
            try typescript.tsParseTypeReference(s);
            if (s.peekKind() != .comma) break;
            try s.advance();
        }
    }
}

/// Parse a single class element
/// Mirrors class element parsing in quickjs.c
fn parseClassElement(s: *State) Error!void {
    const saved_static = s.class.is_static;
    const saved_in_constructor = s.ctx.in_constructor;
    defer {
        s.class.is_static = saved_static;
        s.ctx.in_constructor = saved_in_constructor;
    }

    const modifiers = try parseClassElementModifiers(s);
    if (modifiers.is_declare) return typescript.tsSkipDeclaredField(s);
    if (s.peekKind() == .lbracket and typescript.tsIndexSignatureAhead(s)) return typescript.tsSkipIndexSignature(s);

    const element_source_start = s.currentFunctionSourceStart();
    const method_kind_override = try parseClassMethodPrefix(s);
    if (classAccessorKind(s)) |is_getter| return parseClassAccessor(s, is_getter, modifiers.is_abstract, element_source_start);
    if (s.peekKind() == .private_name) return parseClassPrivateElement(s, modifiers.is_abstract, method_kind_override, element_source_start);
    if (s.peekKind() == .lbracket) {
        try parseClassComputedElement(s, method_kind_override orelse .method, element_source_start);
        if (s.peekKind() == .semicolon) try s.advance();
        return;
    }

    if (try expressions.parseObjectPropertyName(s)) |prop_name| {
        return parseClassNamedElement(s, prop_name.atom, modifiers.is_abstract, method_kind_override, element_source_start);
    }
    if (s.peekKind() == .lbrace) {
        // Static block — parseBlock consumes its own opening '{'.
        if (!s.class.is_static) return s.failUnexpectedToken();
        return parseClassStaticBlock(s);
    }
    return s.failUnexpectedToken();
}

const ClassElementModifiers = struct { is_abstract: bool = false, is_declare: bool = false };

/// Leading member modifiers; `static` lands in `s.class.is_static`.
fn parseClassElementModifiers(s: *State) Error!ClassElementModifiers {
    // Member modifiers. `static` is QuickJS's; the TypeScript words
    // (`public`/`private`/`protected`/`readonly`/`abstract`/`override`/
    // `declare`) follow tsc `nextTokenCanFollowModifier`: a word is a
    // modifier only when a member can start right after it on the same
    // line, otherwise it is the member name. `accessor` (auto-accessors)
    // belongs to the decorators proposal and stays unsupported.
    var modifiers: ClassElementModifiers = .{};
    while (true) {
        const modifier_kind = s.peekKind();
        const Word = enum { none, static, access, readonly, abstract, override, declare };
        var word: Word = .none;
        if (modifier_kind == .kw_static) {
            word = .static;
        } else if (modifier_kind == .kw_public or modifier_kind == .kw_private or modifier_kind == .kw_protected) {
            word = .access;
        } else if (modifier_kind == .ident and !s.token.payload.ident.has_escape) {
            const name = s.lex.atoms.name(s.token.payload.ident.atom) orelse "";
            word = if (std.mem.eql(u8, name, "readonly"))
                .readonly
            else if (std.mem.eql(u8, name, "abstract"))
                .abstract
            else if (std.mem.eql(u8, name, "override"))
                .override
            else if (std.mem.eql(u8, name, "declare"))
                .declare
            else
                .none;
        }
        if (word == .none) break;
        const next_peek = s.peekNext();
        const next = next_peek.kind;
        const has_lt = next_peek.line_terminator;
        if (word != .static and has_lt) break;
        if (!typescript.tsCanFollowClassModifier(next)) break;
        switch (word) {
            .static => s.class.is_static = true,
            .abstract => modifiers.is_abstract = true,
            .declare => modifiers.is_declare = true,
            else => {},
        }
        try s.advance();
    }
    return modifiers;
}

/// `async` / `async *` / `*` before a method name.
fn parseClassMethodPrefix(s: *State) Error!?ParseFunctionKind {
    var method_kind_override: ?ParseFunctionKind = null;
    const async_is_modifier = s.peekKind() == .ident and s.isIdent("async") and switch (s.peekNextKind()) {
        // `async` used as the element name itself.
        .colon, .lparen, .lt, .question, .bang, .assign, .semicolon, .rbrace => false,
        else => true,
    };
    if (async_is_modifier) {
        try s.advance();
        if (s.gotLineTerminator())
            return s.failWithMessage(null, "line terminator is not allowed after async in a class element");
        if (s.peekKind() == .star) {
            try s.advance();
            method_kind_override = .async_generator;
        } else {
            method_kind_override = .async;
        }
    } else if (s.peekKind() == .star) {
        try s.advance();
        method_kind_override = .generator;
    }

    return method_kind_override;
}

/// `get name() {}` / `set name(v) {}`, private, computed or named.
fn parseClassAccessor(s: *State, is_getter: bool, is_abstract: bool, element_source_start: FunctionSourceStart) Error!void {
    try s.advance();
    // Check if this is a private getter/setter (get #x() or set #x())
    if (s.peekKind() == .private_name) {
        const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
        if (identifiers.atomNameEquals(s, private_atom, "#constructor")) return s.failUnexpectedToken();
        try registerClassPrivateElement(s, private_atom, if (is_getter) .getter else .setter);
        try preparePrivateAccessorBinding(s, private_atom, is_getter);
        try s.advance();
        if (!typescript.tsIsMethodStart(s)) {
            return s.failExpectedToken(.lparen);
        }
        if (!(try typescript.tsFunctionHasBodyAhead(s))) return typescript.tsSkipMethodSignature(s, is_abstract);
        // Parse parameters with proper function kind for private getter/setter
        const kind: ParseFunctionKind = if (is_getter) .get else .set;
        try parseClassElementFunction(s, kind, element_source_start);
        try markPrivateBrandNeeded(s);
        try emitStaticClassStackRotate(s);
        // qjs js_parse_class: private accessors retain the class as
        // their home object for super and brand checks.
        try Emitter.op(s, opcode.op.set_home_object);
        if (is_getter) {
            try s.emitScopePutVarInit(private_atom);
        } else {
            const setter_atom = try privateSetterAtom(s, private_atom);
            _ = try addPrivateClassBinding(s, setter_atom, .private_setter);
            try s.emitScopePutVarInit(setter_atom);
        }
        try emitStaticClassStackSwap(s);
    } else if (s.peekKind() == .lbracket) {
        try parseClassComputedMethod(s, if (is_getter) .get else .set, if (is_getter) 1 else 2, element_source_start);
    } else {
        // Regular getter/setter - parse property name (identifier, string, or number)
        const prop_name = (try expressions.parseObjectPropertyName(s)) orelse return s.failExpectedDescription("property name");
        const prop_atom = prop_name.atom;
        if (!s.class.is_static and prop_atom == atom_module.ids.constructor) return s.failUnexpectedToken();
        if (s.class.is_static and prop_atom == atom_module.ids.prototype) return s.failUnexpectedToken();
        if (!typescript.tsIsMethodStart(s)) {
            return s.failExpectedToken(.lparen);
        }
        if (!(try typescript.tsFunctionHasBodyAhead(s))) return typescript.tsSkipMethodSignature(s, is_abstract);
        // Parse parameters with proper function kind for getter/setter
        const kind: ParseFunctionKind = if (is_getter) .get else .set;
        try parseClassElementFunction(s, kind, element_source_start);
        try emitStaticClassStackRotate(s);
        // qjs js_parse_class: define a named getter/setter with
        // OP_DEFINE_METHOD_GETTER/SETTER flags.
        try Emitter.opAtomU8(s, opcode.op.define_method, prop_atom, if (is_getter) 1 else 2);
        try emitStaticClassStackSwap(s);
    }
    return;
}

/// `#x`, `#x = init`, `#m() {}`.
fn parseClassPrivateElement(s: *State, is_abstract: bool, method_kind_override: ?ParseFunctionKind, element_source_start: FunctionSourceStart) Error!void {
    const private_atom = try privateNameAtom(s, s.token.payload.ident.atom);
    if (identifiers.atomNameEquals(s, private_atom, "#constructor")) return s.failUnexpectedToken();
    try s.advance();
    // TypeScript `#x?: T` / `#x!: T`.
    const is_optional_private = s.peekKind() == .question;
    if (s.peekKind() == .question or (s.peekKind() == .bang and !s.gotLineTerminator())) try s.advance();
    if (!typescript.tsIsMethodStart(s)) try typescript.tsParseTypeAnnotationOpt(s);
    if (typescript.tsIsMethodStart(s)) {
        if (!(try typescript.tsFunctionHasBodyAhead(s))) return typescript.tsSkipMethodSignature(s, is_abstract or is_optional_private);
        // Private method
        try registerClassPrivateElement(s, private_atom, .method);
        try parseClassElementFunction(s, method_kind_override orelse .method, element_source_start);
        _ = try addPrivateClassBinding(s, private_atom, .private_method);
        try markPrivateBrandNeeded(s);
        try emitStaticClassStackRotate(s);
        // qjs js_parse_class: private methods need the class home
        // object before their lexical binding is initialized.
        try Emitter.op(s, opcode.op.set_home_object);
        // qjs js_parse_class: give the private method closure its
        // private-symbol display name.
        try Emitter.opAtom(s, opcode.op.set_name, private_atom);
        try s.emitScopePutVarInit(private_atom);
        try emitStaticClassStackSwap(s);
        if (s.peekKind() == .semicolon) try s.advance();
        return;
    } else if (s.peekKind() == .assign) {
        // Private field with initializer
        try registerClassPrivateElement(s, private_atom, .field);
        try addPrivateClassFieldBinding(s, private_atom);
        try s.advance();
        try emitFieldInitializer(s, private_atom, .{ .is_private = true, .has_initializer = true, .is_static = s.class.is_static });
    } else {
        try registerClassPrivateElement(s, private_atom, .field);
        try addPrivateClassFieldBinding(s, private_atom);
        try emitFieldInitializer(s, private_atom, .{ .is_private = true, .is_static = s.class.is_static });
    }
    _ = try s.expectSemicolon();
    return;
}

/// A public method, constructor or field with an ordinary property name.
fn parseClassNamedElement(s: *State, prop_atom: Atom, is_abstract: bool, method_kind_override: ?ParseFunctionKind, element_source_start: FunctionSourceStart) Error!void {
    const saved_in_constructor = s.ctx.in_constructor;
    // TypeScript `x?: T` / `x!: T` / `m?(): T`.
    const is_optional_member = s.peekKind() == .question;
    if (s.peekKind() == .question or (s.peekKind() == .bang and !s.gotLineTerminator())) try s.advance();
    if (!typescript.tsIsMethodStart(s)) try typescript.tsParseTypeAnnotationOpt(s);
    const has_line_terminator_after_name = s.gotLineTerminator();
    const is_constructor = !s.class.is_static and prop_atom == atom_module.ids.constructor;
    if (s.class.is_static and prop_atom == atom_module.ids.prototype and typescript.tsIsMethodStart(s)) return s.failUnexpectedToken();
    if (is_constructor and method_kind_override != null) return s.failUnexpectedToken();
    if (typescript.tsIsMethodStart(s)) {
        // TypeScript overload / abstract / optional signature: no body.
        if (!(try typescript.tsFunctionHasBodyAhead(s))) return typescript.tsSkipMethodSignature(s, is_abstract or is_optional_member);
        // Method or constructor
        if (is_constructor) {
            if (s.class.constructor_cpool_idx != null) return s.failUnexpectedToken();
            s.ctx.in_constructor = true;
        }
        var ctor_snap: compiler.builder.Snapshot = undefined;
        // qjs js_parse_class: the explicit constructor's closure expression is
        // discarded — the class references the child through push_const. Builder
        // snapshot taken BEFORE the emission it may roll back (no boundary bind
        // is pending here).
        ctor_snap = s.activeBuilder().snapshot();
        // Parse parameters with proper function kind for constructor/method
        const kind: ParseFunctionKind = if (is_constructor)
            if (s.class.has_extends) .derived_class_constructor else .class_constructor
        else
            method_kind_override orelse .method;
        try parseClassElementFunction(s, kind, element_source_start);
        if (is_constructor) {
            if (s.last_function_child_index) |child_index| {
                // qjs js_parse_class: discard the constructor's
                // ordinary fclosure expression from the parent.
                s.activeBuilder().rollback(ctor_snap);
                s.class.constructor_cpool_idx = s.curFunc().child_list[child_index].parent_cpool_idx orelse return Error.ParserInvariant;
            }
            s.ctx.in_constructor = saved_in_constructor;
        } else {
            try emitStaticClassStackRotate(s);
            // qjs js_parse_class: define an ordinary named class
            // method with method flag zero.
            try Emitter.opAtomU8(s, opcode.op.define_method, prop_atom, 0);
            try emitStaticClassStackSwap(s);
        }
        // Optional ASI semicolon after method
        if (s.peekKind() == .semicolon) try s.advance();
    } else if (s.peekKind() == .assign) {
        // Field with initializer
        if (isForbiddenPublicFieldName(s, prop_atom)) return s.failUnexpectedToken();
        try s.advance();
        try emitFieldInitializer(s, prop_atom, .{ .has_initializer = true, .is_static = s.class.is_static });
        _ = try s.expectSemicolon();
    } else if (s.peekKind() == .semicolon) {
        // Field without initializer, with semicolon
        if (isForbiddenPublicFieldName(s, prop_atom)) return s.failUnexpectedToken();
        try emitPublicFieldNoInitializer(s, prop_atom);
        try s.advance();
    } else {
        if (isForbiddenPublicFieldName(s, prop_atom)) return s.failUnexpectedToken();
        try emitPublicFieldNoInitializer(s, prop_atom);
        if (s.peekKind() == .semicolon) {
            try s.advance();
        } else if (!(has_line_terminator_after_name or s.peekKind() == .eof or s.peekKind() == .rbrace)) {
            return s.failUnexpectedToken();
        }
    }
}

fn classAccessorKind(s: *State) ?bool {
    if (!(s.peekKind() == .ident and (s.isIdent("get") or s.isIdent("set")))) return null;

    const next_peek = s.peekNext();
    const next = next_peek.kind;
    const has_line_terminator = next_peek.line_terminator;
    if (has_line_terminator) return null;
    if (next == .lparen or
        next == .lt or
        next == .question or
        next == .bang or
        next == .colon or
        next == .assign or
        next == .semicolon or
        next == .rbrace)
    {
        return null;
    }
    return s.isIdent("get");
}

fn registerClassPrivateElement(s: *State, atom_id: Atom, kind: ClassPrivateElementKind) Error!void {
    for (s.class_private_elements.items) |entry| {
        if (entry.atom != atom_id) continue;
        if (classPrivateElementsConflict(entry, kind, s.class.is_static)) {
            return s.failUnexpectedToken();
        }
    }
    try s.class_private_elements.append(s.memory.allocator, .{
        .atom = atom_id,
        .kind = kind,
        .is_static = s.class.is_static,
    });
}

/// QuickJS `add_private_class_field`: every private element is represented
/// by a lexical const VarDef. Only the parser-time row retains the static
/// discriminator used to validate getter/setter pairing.
fn addPrivateClassBinding(s: *State, atom_id: Atom, kind: function_def_mod.VarKind) Error!u16 {
    const idx = try declarations.addScopeVar(s, atom_id, kind, .{ .is_lexical = true, .is_const = true });
    if (idx < 0 or @as(usize, @intCast(idx)) >= s.curFunc().vars.len) return Error.ParserInvariant;
    s.curFunc().vars[@intCast(idx)].is_static_private = s.class.is_static;
    return @intCast(idx);
}

fn addPrivateClassFieldBinding(s: *State, atom_id: Atom) Error!void {
    _ = try addPrivateClassBinding(s, atom_id, .private_field);
    // qjs js_parse_class: materialize the private field's unique
    // symbol before initializing its lexical binding.
    try Emitter.opAtom(s, opcode.op.private_symbol, atom_id);
    try s.emitScopePutVarInit(atom_id);
}

fn preparePrivateAccessorBinding(s: *State, atom_id: Atom, is_getter: bool) Error!void {
    if (functions.findCurrentScopeVar(s, atom_id)) |idx| {
        const vd = &s.curFunc().vars[idx];
        if (vd.is_static_private != s.class.is_static) return s.failUnexpectedToken();
        const expected: function_def_mod.VarKind = if (is_getter) .private_setter else .private_getter;
        if (vd.var_kind != expected) return s.failUnexpectedToken();
        vd.var_kind = .private_getter_setter;
        return;
    }
    _ = try addPrivateClassBinding(s, atom_id, if (is_getter) .private_getter else .private_setter);
}

fn privateSetterAtom(s: *State, private_atom: Atom) Error!Atom {
    const name = s.atoms.name(private_atom) orelse return Error.InvalidIdentifier;
    const suffix = "<set>";
    const bytes = try s.memory.alloc(u8, name.len + suffix.len);
    defer s.memory.free(u8, bytes);
    @memcpy(bytes[0..name.len], name);
    @memcpy(bytes[name.len..], suffix);
    return s.atoms.newSymbol(bytes, .private);
}

fn markPrivateBrandNeeded(s: *State) Error!void {
    if (s.class.is_static) {
        s.class.static_private_brand_needed = true;
        return;
    }
    s.class.instance_private_brand_needed = true;
    const child_index = try ensureClassFieldsInitFunction(s);
    const parent = s.curFunc();
    if (child_index >= parent.child_list.len) return Error.ParserInvariant;
    const init_fd = parent.child_list[child_index];
    // qjs js_parse_class: enable the dormant instance-brand prologue
    // after the first private method or accessor requires it.
    const v2b = init_fd.builder orelse return Error.ParserInvariant;
    if (v2b.code_len == 0) return Error.ParserInvariant;
    switch (v2b.code[0]) {
        opcode.op.push_false => v2b.code[0] = opcode.op.push_true,
        opcode.op.push_true => {},
        else => return Error.ParserInvariant,
    }
}

fn isForbiddenPublicFieldName(s: *State, atom_id: Atom) bool {
    if (!s.class.is_static) return atom_id == atom_module.ids.constructor;
    return atom_id == atom_module.ids.constructor or atom_id == atom_module.ids.prototype;
}

/// The current class name, or null when the token cannot name a class.
/// Post-TGC S3-c the id is borrowed — `CompileAtomScope` roots it and the
/// caller does not free.
fn classNameAtom(s: *State) ?Atom {
    const kind = s.peekKind();
    if (kind == .ident) {
        const atom_id = s.token.payload.ident.atom;
        if (escapedIdentifierIsReservedClassName(s, atom_id, s.token.payload.ident.has_escape)) return null;
        return atom_id;
    }
    if (kind == .kw_await and identifiers.canUseAwaitAsIdentifier(s)) {
        return tok.keywordAtom(kind);
    }
    return null;
}

fn escapedIdentifierIsReservedClassName(s: *State, atom_id: Atom, has_escape: bool) bool {
    if (!has_escape) return false;
    return identifiers.escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape) or
        ((s.lex.is_module or s.ctx.in_async or s.ctx.in_class_static_block) and identifiers.atomNameEquals(s, atom_id, "await"));
}

/// Parser state that emitting into a class field initializer function
/// displaces. `enterFieldInitFunction` takes it and installs the initializer
/// context; `leaveFieldInitFunction` puts it back and pops the function.
///
/// `StaticBlockContext` explicitly extends these fields with the
/// additional displacements unique to a class static block.
const FieldInitContext = struct {
    last_opcode_source_offset: ?u32,
    scope_level: i32,
    is_strict: bool,
    lex_is_strict: bool,
    ctx: parse_state.FunctionContext,
    last_function_child_index: ?u16,
};

const StaticBlockContext = struct {
    field_init: FieldInitContext,
    is_static: bool,
};

fn enterFieldInitFunction(s: *State, init_fd: *function_def_mod.FunctionDef) Error!FieldInitContext {
    const saved: FieldInitContext = .{
        .last_opcode_source_offset = s.last_opcode_source_offset,
        .scope_level = s.scope_level,
        .is_strict = s.is_strict,
        .lex_is_strict = s.lex.is_strict_mode,
        .ctx = s.ctx,
        .last_function_child_index = s.last_function_child_index,
    };
    // Nothing below `pushFunction` can fail, so a caller that received a
    // context is always paired with exactly one `leaveFieldInitFunction`.
    try s.pushFunction(init_fd);
    s.last_opcode_source_offset = null;
    s.scope_level = 0;
    s.is_strict = true;
    s.lex.is_strict_mode = true;
    s.ctx.allow_super = true;
    s.ctx.allow_super_call = false;
    s.ctx.new_target_allowed = true;
    s.ctx.in_constructor = false;
    return saved;
}

fn leaveFieldInitFunction(s: *State, saved: FieldInitContext) void {
    _ = s.popFunction();
    s.last_opcode_source_offset = saved.last_opcode_source_offset;
    s.scope_level = saved.scope_level;
    s.is_strict = saved.is_strict;
    s.lex.is_strict_mode = saved.lex_is_strict;
    s.ctx = saved.ctx;
    s.last_function_child_index = saved.last_function_child_index;
}

fn enterStaticBlockFunction(s: *State, init_fd: *function_def_mod.FunctionDef) Error!StaticBlockContext {
    const saved: StaticBlockContext = .{
        .field_init = try enterFieldInitFunction(s, init_fd),
        .is_static = s.class.is_static,
    };
    s.ctx.in_class_static_block = true;
    s.class.is_static = false;
    return saved;
}

fn leaveStaticBlockFunction(s: *State, saved: StaticBlockContext) void {
    leaveFieldInitFunction(s, saved.field_init);
    s.class.is_static = saved.is_static;
}

/// Leftover class field-initializer emit. candidate100 still compiled
/// two leftover copies (`emitInstanceFieldInitializer` 1116 /
/// `emitStaticFieldInitializer` 1326). candidate102 still compiles a
/// third leftover (`emitInstanceComputedPublicFieldInitializer` 1016
/// beside this helper 1314, extra 1016, 5.3% match). The leftover is
/// enter-child + receiver + optional init + define + drop. Comptime
/// identity is static vs instance vs computed (which child, `this`
/// opcode, get-key / define_array_el arm). Take those at runtime.
/// Private names stay `inline` and pass only flags — no leftover setup
/// at the wrapper (knives 94/98).
/// Shape of one class field: the four flags that select the initializer
/// function, the key fetch, and the define opcode.
const FieldInitOptions = struct {
    is_private: bool = false,
    is_computed: bool = false,
    has_initializer: bool = false,
    is_static: bool = false,
};

noinline fn emitFieldInitializer(s: *State, atom_id: Atom, options: FieldInitOptions) Error!void {
    const is_private = options.is_private;
    const is_computed = options.is_computed;
    const has_initializer = options.has_initializer;
    const is_static = options.is_static;
    const child_index = if (is_static)
        try ensureClassStaticInitFunction(s)
    else
        try ensureClassFieldsInitFunction(s);
    const parent_fd = s.curFunc();
    if (child_index >= parent_fd.child_list.len) return Error.ParserInvariant;
    const init_fd = parent_fd.child_list[child_index];

    const saved_ctx = try enterFieldInitFunction(s, init_fd);
    errdefer leaveFieldInitFunction(s, saved_ctx);

    if (is_static) {
        try s.emitScopeGetVar(atom_this);
    } else {
        // qjs js_parse_class: instance field initializers begin from the
        // receiver supplied as this.
        try Emitter.op(s, opcode.op.push_this);
    }
    if (is_private or is_computed) try s.emitScopeGetVar(atom_id);
    if (has_initializer) {
        try expressions.parseAssignExpr(s);
        if (is_private or is_computed)
            try functions.setObjectNameComputed(s)
        else
            try functions.setObjectName(s, atom_id);
    } else {
        // qjs js_parse_class: an uninitialized field receives undefined
        // in the initializer child.
        try Emitter.op(s, opcode.op.undefined);
    }
    if (is_private) {
        try Emitter.op(s, opcode.op.define_private_field);
    } else if (is_computed) {
        try Emitter.op(s, opcode.op.define_array_el);
    } else {
        try Emitter.opAtom(s, opcode.op.define_field, atom_id);
    }
    try Emitter.op(s, opcode.op.drop);

    leaveFieldInitFunction(s, saved_ctx);
}

fn emitPublicFieldNoInitializer(s: *State, atom_id: Atom) Error!void {
    try emitFieldInitializer(s, atom_id, .{ .is_static = s.class.is_static });
}

fn ensureClassFieldsInitFunction(s: *State) Error!usize {
    if (s.class.fields_init_child_index) |child_index| return child_index;
    const child_index = try createClassFieldsInitFunction(s, true);
    s.class.fields_init_child_index = @intCast(child_index);
    return child_index;
}

fn ensureClassStaticInitFunction(s: *State) Error!usize {
    if (s.class.static_init_child_index) |child_index| return child_index;
    const child_index = try createClassFieldsInitFunction(s, false);
    s.class.static_init_child_index = @intCast(child_index);
    return child_index;
}

fn createClassFieldsInitFunction(s: *State, include_instance_brand_prologue: bool) Error!usize {
    const parent_fd = s.curFunc();
    const child_fd = try functions.newChildFunctionDef(s, parent_fd, atom_class_fields_init, s.currentSourcePosition());
    errdefer s.discardFunctionDef(child_fd);
    child_fd.is_strict_mode = true;
    child_fd.func_type = .method;
    child_fd.func_kind = .normal;
    child_fd.has_prototype = false;
    child_fd.has_home_object = true;
    child_fd.need_home_object = true;
    child_fd.has_this_binding = true;
    child_fd.new_target_allowed = true;
    child_fd.super_allowed = true;
    child_fd.arguments_allowed = false;
    _ = try child_fd.appendScope(-1);
    try s.ensureBuilderForFd(child_fd);
    if (include_instance_brand_prologue) {
        // qjs js_parse_class: dormant instance-brand prologue (push_false patched to
        // push_true by the first private method/accessor); the skip target is born
        // as a LabelId instead of the legacy absolute base+15.
        const v2b = child_fd.builder.?;
        try v2b.emitOp(opcode.op.push_false);
        const skip = try v2b.newLabel();
        try v2b.emitJump(opcode.op.if_false, skip);
        try v2b.emitOp(opcode.op.push_this);
        try v2b.emitAtomOpU16Owned(opcode.op.scope_get_var, atom_module.ids.home_object, 0);
        try v2b.emitOp(opcode.op.add_brand);
        try v2b.bindLabel(skip);
        v2b.invalidateLastOpcode();
    }
    const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
    child_fd.parent_cpool_idx = cpool_idx;
    try parent_fd.addChild(child_fd);
    const child_index: u16 = @intCast(parent_fd.child_list.len - 1);
    return child_index;
}

fn finishClassFieldsInitFunction(s: *State) Error!void {
    const child_index = s.class.fields_init_child_index orelse return;
    try finishClassInitFunction(s, child_index);
}

fn finishClassStaticInitFunction(s: *State) Error!void {
    const child_index = s.class.static_init_child_index orelse return;
    try finishClassInitFunction(s, child_index);
}

fn finishClassInitFunction(s: *State, child_index: usize) Error!void {
    const parent_fd = s.curFunc();
    if (child_index >= parent_fd.child_list.len) return Error.ParserInvariant;
    const init_fd = parent_fd.child_list[child_index];
    // qjs js_is_live_code shape over the child's temp stream: get_prev_opcode
    // is Builder.last_opcode_pos (an invalidated merge answers live).
    const v2b = init_fd.builder orelse return Error.ParserInvariant;
    const needs_return = if (v2b.last_opcode_pos) |last_pos| switch (v2b.code[last_pos]) {
        opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.throw => false,
        else => true,
    } else true;
    if (needs_return) {
        try v2b.emitOp(opcode.op.return_undef);
    }
}

fn registerClassPrivateBoundName(s: *State, atom_id: Atom) Error!void {
    for (s.class_private_bound_names.items) |existing| {
        if (existing == atom_id) return;
    }
    // The atom id is borrowed; the enclosing CompileAtomScope is its root.
    try s.class_private_bound_names.append(s.memory.allocator, atom_id);
}

pub fn classPrivateNameIsBound(s: *State, atom_id: Atom) bool {
    for (s.class_private_bound_names.items) |existing| {
        if (existing == atom_id) return true;
    }
    return false;
}

fn classPrivateElementsConflict(
    existing: ClassPrivateElement,
    new_kind: ClassPrivateElementKind,
    new_is_static: bool,
) bool {
    const getter_setter_pair =
        (existing.kind == .getter and new_kind == .setter) or
        (existing.kind == .setter and new_kind == .getter);
    return !getter_setter_pair or existing.is_static != new_is_static;
}

pub fn privateNameAtom(s: *State, atom_id: Atom) Error!Atom {
    s.features.insert(.private_name);
    if (findClassPrivateBoundName(s, atom_id, 0)) |private_atom| {
        return private_atom;
    }
    return newClassPrivateAtom(s, atom_id);
}

fn privateNameDeclarationAtom(s: *State, atom_id: Atom, bound_start: usize) Error!Atom {
    s.features.insert(.private_name);
    if (findClassPrivateBoundName(s, atom_id, bound_start)) |private_atom| {
        return private_atom;
    }
    return newClassPrivateAtom(s, atom_id);
}

pub fn findClassPrivateBoundName(s: *State, atom_id: Atom, bound_start: usize) ?Atom {
    var i = s.class_private_bound_names.items.len;
    while (i > bound_start) {
        i -= 1;
        const private_atom = s.class_private_bound_names.items[i];
        if (privateAtomMatchesName(s, private_atom, atom_id)) return private_atom;
    }
    return null;
}

fn privateAtomMatchesName(s: *State, private_atom: Atom, atom_id: Atom) bool {
    const private_name = s.atoms.name(private_atom) orelse return false;
    const name = s.atoms.name(atom_id) orelse return false;
    if (std.mem.eql(u8, private_name, name)) return true;
    if (name.len > 0 and name[0] == '#') return false;
    return private_name.len == name.len + 1 and
        private_name[0] == '#' and
        std.mem.eql(u8, private_name[1..], name);
}

fn newClassPrivateAtom(s: *State, atom_id: Atom) Error!Atom {
    const name = s.atoms.name(atom_id) orelse return Error.InvalidIdentifier;
    if (name.len > 0 and name[0] == '#') {
        return s.atoms.newSymbol(name, .private);
    }
    const bytes = try s.memory.alloc(u8, name.len + 1);
    defer s.memory.free(u8, bytes);
    bytes[0] = '#';
    @memcpy(bytes[1..], name);
    return s.atoms.newSymbol(bytes, .private);
}

fn classComputedFieldTempAtom(s: *State) Error!Atom {
    const temp_name = try std.fmt.allocPrint(s.memory.allocator, "__class_computed_field_{d}", .{s.with_scope_id});
    defer s.memory.allocator.free(temp_name);
    s.with_scope_id += 1;
    return s.atoms.internString(temp_name);
}

fn parseClassElementFunction(s: *State, kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void {
    const saved_parameter_properties = s.current_parameter_properties;
    if (kind.isConstructor()) {
        s.current_parameter_properties = std.ArrayList(Atom).empty;
    } else {
        s.current_parameter_properties = null;
    }
    defer {
        if (kind.isConstructor()) {
            if (s.current_parameter_properties) |*props| {
                functions.deinitOwnedParserAtoms(s, props);
            }
        }
        s.current_parameter_properties = saved_parameter_properties;
    }

    try functions.parseFunctionParamsAndBody(s, kind, source_start, .{ .is_method = true });
}

fn parseClassComputedName(s: *State) Error!void {
    try s.expectToken(.lbracket);
    try expressions.parseAssignExpr2(s, ParseFlags.default);
    // qjs js_parse_class: canonicalize a computed class element name
    // before it is stored or consumed by define_method_computed.
    try Emitter.op(s, opcode.op.to_propkey);
    try s.expectToken(.rbracket);
}

/// qjs js_parse_class: a static member's definition runs with the class
/// stack rotated (`perm3`) and restored (`swap`) around it, and a static
/// computed key is evaluated with the static constructor exposed
/// (`swap`). Instance members see the stack as-is.
fn emitStaticClassStackRotate(s: *State) Error!void {
    if (s.class.is_static) try Emitter.op(s, opcode.op.perm3);
}

fn emitStaticClassStackSwap(s: *State) Error!void {
    if (s.class.is_static) try Emitter.op(s, opcode.op.swap);
}

/// `[key]` method or field of a class, static or instance.
fn parseClassComputedElement(s: *State, kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void {
    try emitStaticClassStackSwap(s);
    try parseClassComputedName(s);
    if (s.peekKind() == .question or (s.peekKind() == .bang and !s.gotLineTerminator())) try s.advance();
    if (!typescript.tsIsMethodStart(s)) try typescript.tsParseTypeAnnotationOpt(s);
    if (typescript.tsIsMethodStart(s)) {
        if (!(try typescript.tsFunctionHasBodyAhead(s))) {
            try typescript.tsSkipMethodSignature(s, false);
            try emitStaticClassStackSwap(s);
            return;
        }
        try parseClassElementFunction(s, kind, source_start);
        try Emitter.opU8(s, opcode.op.define_method_computed, 0);
        try emitStaticClassStackSwap(s);
        return;
    }
    if (kind != .method) return Error.ParserInvariant;

    // The evaluated key is kept in a synthetic const for the field
    // initializer function.
    const key_atom = try classComputedFieldTempAtom(s);
    _ = try declarations.defineVar(s, key_atom, .const_);
    try s.emitScopePutVarInit(key_atom);
    try emitStaticClassStackSwap(s);

    const has_initializer = s.peekKind() == .assign;
    if (has_initializer) try s.advance();
    try emitFieldInitializer(s, key_atom, .{ .is_computed = true, .has_initializer = has_initializer, .is_static = s.class.is_static });
    _ = try s.expectSemicolon();
}

fn parseClassComputedMethod(s: *State, kind: ParseFunctionKind, define_flags: u8, source_start: FunctionSourceStart) Error!void {
    try emitStaticClassStackSwap(s);
    try parseClassComputedName(s);
    if (!typescript.tsIsMethodStart(s)) return s.failExpectedToken(.lparen);
    try parseClassElementFunction(s, kind, source_start);
    // qjs js_parse_class: define the computed getter/setter with its
    // method-kind flag.
    try Emitter.opU8(s, opcode.op.define_method_computed, define_flags);
    try emitStaticClassStackSwap(s);
}

fn parseClassStaticBlock(s: *State) Error!void {
    const child_index = try ensureClassStaticInitFunction(s);
    const parent_fd = s.curFunc();
    if (child_index >= parent_fd.child_list.len) return Error.ParserInvariant;
    const init_fd = parent_fd.child_list[child_index];

    const saved_ctx = try enterStaticBlockFunction(s, init_fd);
    errdefer leaveStaticBlockFunction(s, saved_ctx);

    try functions.parseFunctionParamsAndBody(s, .class_static_block, null, .{});
    try s.emitScopeGetVar(atom_this);
    // qjs js_parse_class: call the static-block
    // closure with the class constructor as receiver.
    try Emitter.op(s, opcode.op.swap);
    // qjs js_parse_class: the static block takes no
    // explicit arguments.
    try Emitter.callOp(s, opcode.op.call_method, 0);
    // qjs js_parse_class: discard the static block's
    // completion value.
    try Emitter.op(s, opcode.op.drop);

    leaveStaticBlockFunction(s, saved_ctx);
}

/// Parse class body
/// Mirrors `js_parse_class_body` in quickjs.c
fn parseClassBodyAfterOpen(s: *State) Error!void {
    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        if (s.peekKind() == .semicolon) {
            try s.advance();
            continue;
        }
        try parseClassElement(s);
    }

    try s.expectToken(.rbrace);
}

fn collectClassPrivateBoundNames(s: *State, bound_start: usize) Error!void {
    if (s.peekKind() != .lbrace) return;

    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);

    var brace_depth: usize = 1;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var prev_kind: tok.TokenKind = .eof;
    while (brace_depth > 0) {
        var scan_token = s.lex.next() catch |err| return lookahead.mapLookaheadLexerError(s, err);
        defer s.lex.freeToken(&scan_token);
        const k = scan_token.val;
        if (k == .eof) break;

        if (k == .private_name and
            brace_depth == 1 and
            paren_depth == 0 and
            bracket_depth == 0 and
            prev_kind != .dot and
            prev_kind != .question_mark_dot)
        {
            const private_atom = try privateNameDeclarationAtom(s, scan_token.payload.ident.atom, bound_start);
            try registerClassPrivateBoundName(s, private_atom);
        }

        switch (k) {
            .slash, .div_assign => {
                if (try lookahead.skipRegexpInPredeclareScan(s, prev_kind)) {
                    prev_kind = .regexp;
                    continue;
                }
            },
            .template => {
                try lookahead.skipTemplateInPredeclareScan(s, scan_token);
                prev_kind = .template;
                continue;
            },
            .lbrace => brace_depth += 1,
            .rbrace => {
                brace_depth -= 1;
                if (brace_depth == 0) break;
            },
            .lparen => paren_depth += 1,
            .rparen => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            .lbracket => bracket_depth += 1,
            .rbracket => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            else => {},
        }
        prev_kind = k;
    }
}

fn emitClassLocalInitFromClassStack(s: *State, local_idx: u16) Error!void {
    // qjs js_parse_class: initialize the inner class-name binding
    // while preserving the constructor/prototype stack order.
    try Emitter.op(s, opcode.op.swap);
    try Emitter.op(s, opcode.op.dup);
    try Emitter.opU16(s, opcode.op.put_loc_check_init, local_idx);
    try Emitter.op(s, opcode.op.swap);
}

fn emitClassFieldsInitValue(s: *State, class_fields_init_child_index: ?u16) Error!void {
    if (class_fields_init_child_index) |child_index| {
        const parent_fd = s.curFunc();
        if (child_index >= parent_fd.child_list.len) return Error.ParserInvariant;
        const cpool_idx = parent_fd.child_list[child_index].parent_cpool_idx orelse return Error.ParserInvariant;
        try s.emitFClosure(cpool_idx);
        // qjs emit_class_init_end: bind the initializer closure to the
        // class home object.
        try Emitter.op(s, opcode.op.set_home_object);
    } else {
        // qjs js_parse_class: absent instance fields initialize the
        // hidden class_fields_init binding with undefined.
        try Emitter.op(s, opcode.op.undefined);
    }
}

fn emitClassFieldsInitLocalInitFromClassStack(s: *State, fields_init_local_idx: u16, class_fields_init_child_index: ?u16) Error!void {
    try emitClassFieldsInitValue(s, class_fields_init_child_index);
    // qjs js_parse_class: initialize the hidden fields-initializer
    // lexical from the just-created closure or undefined.
    try Emitter.opU16(s, opcode.op.put_loc_check_init, fields_init_local_idx);
}

fn emitClassStaticInitCall(s: *State, class_static_init_child_index: ?u16) Error!void {
    const child_index = class_static_init_child_index orelse return;
    const parent_fd = s.curFunc();
    if (child_index >= parent_fd.child_list.len) return Error.ParserInvariant;
    const cpool_idx = parent_fd.child_list[child_index].parent_cpool_idx orelse return Error.ParserInvariant;

    // The class constructor is the sole stack value here. Duplicate it as
    // the call receiver/home object, then invoke the lexical static
    // initializer immediately. Mirrors quickjs.c.
    // qjs js_parse_class: invoke the static
    // initializer with the constructor as home object and receiver.
    try Emitter.op(s, opcode.op.dup);
    try s.emitFClosure(@intCast(cpool_idx));
    try Emitter.op(s, opcode.op.set_home_object);
    try Emitter.callOp(s, opcode.op.call_method, 0);
    try Emitter.op(s, opcode.op.drop);
}

/// The class stack is `[constructor, prototype]`. Private instance members
/// use the prototype as their home object, so pre-create its brand before
/// user code can make the prototype non-extensible. Static members brand
/// the constructor itself. Both sequences preserve the class stack.
const PrivateBrandNeeds = struct { instance: bool, static_: bool };

fn emitClassPrivateBrands(s: *State, needs: PrivateBrandNeeds) Error!void {
    if (needs.instance) {
        // qjs js_parse_class: pre-create the instance brand on the
        // prototype while preserving the class stack.
        try Emitter.op(s, opcode.op.dup);
        try Emitter.op(s, opcode.op.null);
        try Emitter.op(s, opcode.op.swap);
        try Emitter.op(s, opcode.op.add_brand);
    }
    if (needs.static_) {
        // qjs js_parse_class: add the static private brand to the
        // constructor and restore constructor/prototype order.
        try Emitter.op(s, opcode.op.swap);
        try Emitter.op(s, opcode.op.dup);
        try Emitter.op(s, opcode.op.dup);
        try Emitter.op(s, opcode.op.add_brand);
        try Emitter.op(s, opcode.op.swap);
    }
}

fn emitClassDefineOperands(s: *State, cpool_idx: u16) Error!void {
    // qjs js_parse_class: push the constructor child constant before
    // define_class consumes it.
    try Emitter.opU32(s, opcode.op.push_const, cpool_idx);
}

/// Parse class declaration or expression
/// Mirrors `js_parse_class` in quickjs.c
/// Class declarations return their name as an owned atom; expressions
/// return null. The caller frees a returned name.
pub fn parseClass(s: *State, is_decl: bool) Error!?Atom {
    s.features.insert(.class_);
    const class_source_start = s.currentTokenStartOffset();
    try s.expectToken(.kw_class);

    // Parse class name (required for declarations, optional for expressions)
    var class_name: ?Atom = null;
    if (is_decl) {
        class_name = classNameAtom(s) orelse return s.failExpectedDescription("class name");
        try s.advance();
    } else {
        if (classNameAtom(s)) |name_atom| {
            class_name = name_atom;
            try s.advance();
        }
    }
    // TypeScript `class C<T>`.
    if (typescript.tsAtLess(s)) try typescript.tsParseTypeParameters(s);

    var parsed = try parseClassTail(s, is_decl, class_name, class_source_start);
    defer s.activeBuilder().discardSegment(&parsed.runtime_seg);
    if (is_decl) {
        try emitClassDeclaration(s, class_name.?, &parsed);
        return class_name;
    }
    try emitClassExpression(s, class_name, &parsed);
    return null;
}

/// What parsing the ClassTail produced, for the define_class lowering.
const ParsedClass = struct {
    has_extends: bool,
    constructor_cpool_idx: u16,
    fields_init_child_index: ?u16,
    static_init_child_index: ?u16,
    instance_private_brand_needed: bool,
    static_private_brand_needed: bool,
    /// Inner `const` binding of the class name (TDZ inside the body).
    name_local_idx: ?u16,
    /// Hidden local holding the fields initializer closure.
    fields_init_local_idx: u16,
    private_scope_level: i32,
    outer_scope_level: i32,
    /// The body's runtime bytecode, detached to be spliced after define_class.
    runtime_seg: compiler.builder.DetachedSegment,
};

/// Heritage, the two inner scopes, the body, the synthetic initializer
/// functions and the constructor. Parses under the class context and
/// restores the enclosing one; emits nothing into the parent stream except
/// the constructor's placeholder (its closure is rolled back).
fn parseClassTail(s: *State, is_decl: bool, class_name: ?Atom, class_source_start: usize) Error!ParsedClass {
    // Parse heritage (extends clause)
    const outer_class = s.class;
    const saved_is_strict = s.is_strict;
    const saved_lex_is_strict = s.lex.is_strict_mode;
    const saved_class_private_elements_len = s.class_private_elements.items.len;
    const saved_class_private_bound_names_len = s.class_private_bound_names.items.len;
    errdefer {
        s.truncateClassPrivateElements(saved_class_private_elements_len);
        s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
        s.class = outer_class;
        s.is_strict = saved_is_strict;
        s.lex.is_strict_mode = saved_lex_is_strict;
    }

    s.class = .{ .in_body = true, .has_extends = s.peekKind() == .kw_extends };
    s.is_strict = true;
    // The whole ClassTail — heritage, computed keys, method/getter/setter
    // bodies, and field initializers — is strict code for the LEXER as
    // well: legacy octal literals (08) and octal/\8 string escapes
    // are SyntaxErrors. Mirrors js_parse_class quickjs.c
    // ("classes are parsed and executed in strict mode",
    // fd->js_mode |= JS_MODE_STRICT) gating the tokenizer octal checks
    // (quickjs.c number literals, 22530-22536 string escapes).
    s.lex.is_strict_mode = true;
    // QuickJS creates the class-name scope even for an anonymous class.
    // The binding itself is appended only after heritage parsing, but the
    // completed scope chain still makes a named class TDZ-visible there.
    var class_outer_scope = try s.openScope();
    errdefer class_outer_scope.pop(s);
    try parseClassHeritage(s);
    var name_local_idx: ?u16 = null;
    if (class_name) |class_atom| {
        name_local_idx = switch (try declarations.defineVar(s, class_atom, .const_)) {
            .local => |idx| idx,
            else => unreachable,
        };
    }
    try collectClassPrivateBoundNames(s, saved_class_private_bound_names_len);
    try s.expectToken(.lbrace);
    var class_private_scope = try s.openScope();
    errdefer class_private_scope.pop(s);
    const fields_init_local_idx: u16 = switch (try declarations.defineVar(s, atom_class_fields_init, .const_)) {
        .local => |idx| idx,
        else => unreachable,
    };
    s.curFunc().vars[fields_init_local_idx].tdz_emitted_at_decl = true;

    // Parse class body. Constructor parsing records a child FunctionDef;
    // class definition bytecode references that child through push_const /
    // define_class instead of the normal fclosure expression path.
    var class_mark: compiler.builder.Snapshot = undefined;
    class_mark = s.activeBuilder().snapshot();
    try parseClassBodyAfterOpen(s);
    const class_source_end = s.last_token_end_offset;
    try finishClassFieldsInitFunction(s);
    try finishClassStaticInitFunction(s);
    var runtime_seg: compiler.builder.DetachedSegment = .{};
    errdefer s.activeBuilder().discardSegment(&runtime_seg);
    // qjs js_parse_class: the body's runtime bytecode is
    // deferred and re-emitted after define_class; v2 detaches the builder
    // tail — LabelIds are function-global, so no operand rebase exists.
    runtime_seg = try Emitter.detachTail(s, class_mark);
    // The legacy class move intentionally transports only code+atoms;
    // its truncate removes body source slots before the runtime block
    // is appended. Preserve that exact pc2line product in v2.
    Emitter.discardDetachedSources(s, &runtime_seg);
    const default_constructor_name = class_name orelse if (is_decl) s.root_name else atom_module.ids.empty_string;
    const constructor_cpool_idx = s.class.constructor_cpool_idx orelse
        try appendDefaultClassConstructor(s, default_constructor_name);
    const private_scope_level = s.scope_level;
    class_private_scope.pop(s);
    const outer_scope_level = s.scope_level;
    class_outer_scope.pop(s);
    try s.setChildFunctionSourceByCpoolIndex(constructor_cpool_idx, class_source_start, class_source_end);
    const parsed: ParsedClass = .{
        .has_extends = s.class.has_extends,
        .constructor_cpool_idx = constructor_cpool_idx,
        .fields_init_child_index = s.class.fields_init_child_index,
        .static_init_child_index = s.class.static_init_child_index,
        .instance_private_brand_needed = s.class.instance_private_brand_needed,
        .static_private_brand_needed = s.class.static_private_brand_needed,
        .name_local_idx = name_local_idx,
        .fields_init_local_idx = fields_init_local_idx,
        .private_scope_level = private_scope_level,
        .outer_scope_level = outer_scope_level,
        .runtime_seg = runtime_seg,
    };

    s.class = outer_class;
    s.is_strict = saved_is_strict;
    s.lex.is_strict_mode = saved_lex_is_strict;
    s.truncateClassPrivateElements(saved_class_private_elements_len);
    s.truncateClassPrivateBoundNames(saved_class_private_bound_names_len);
    return parsed;
}

/// `class C {}` statement: define the class, run the deferred body, bind
/// `C` in the containing scope (qjs js_parse_class).
fn emitClassDeclaration(s: *State, class_name: Atom, parsed: *ParsedClass) Error!void {
    var class_decl_local_idx: ?u16 = null;
    var top_level_class_binding = false;
    // QuickJS appends the outer class-statement LET only after the
    // complete ClassTail (including computed keys and the synthetic
    // fields initializer) has been parsed.  The inner CONST above is
    // the binding visible from heritage/body code; final scope-entry
    // lowering still establishes the outer LET's TDZ before runtime
    // evaluation starts.
    if (s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and identifiers.hasKnownBinding(s, class_name)) {
        return s.failExpectedDescription("non-conflicting declaration");
    }
    switch (try declarations.defineVar(s, class_name, .let_)) {
        .local => |idx| class_decl_local_idx = idx,
        .global => top_level_class_binding = true,
        .argument => unreachable,
    }
    if (!parsed.has_extends) {
        // qjs js_parse_class: a base class supplies undefined as
        // the heritage operand to define_class.
        try Emitter.op(s, opcode.op.undefined);
    }
    // qjs js_parse_class: establish the hidden initializer local's TDZ
    // before defining the class.
    try Emitter.opU16(s, opcode.op.set_loc_uninitialized, parsed.fields_init_local_idx);
    try emitClassDefineOperands(s, parsed.constructor_cpool_idx);
    // qjs js_parse_class: define the declaration's class object
    // with its heritage flag and retained name atom.
    try Emitter.opAtomU8(s, opcode.op.define_class, class_name, if (parsed.has_extends) 1 else 0);
    try emitClassPrivateBrands(s, .{ .instance = parsed.instance_private_brand_needed, .static_ = parsed.static_private_brand_needed });
    // qjs js_parse_class: the deferred runtime
    // block is spliced after define_class.
    try Emitter.spliceSegment(s, &parsed.runtime_seg);
    // ClassElement computed names run while the inner class binding is
    // still in TDZ (`class C { [C](){} }` must throw). Initialize the
    // name only after those keys (and method definitions) have run.
    if (parsed.name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
    try emitClassFieldsInitLocalInitFromClassStack(s, parsed.fields_init_local_idx, parsed.fields_init_child_index);
    // qjs js_parse_class: drop the prototype after installing the
    // fields initializer.
    try Emitter.op(s, opcode.op.drop);
    try emitClassStaticInitCall(s, parsed.static_init_child_index);
    // Parsing restores the outer scope identity before emitting this
    // deferred class runtime sequence so the declaration binding is
    // defined in its containing scope. Keep the runtime exits at the
    // canonical QuickJS position: after the private/name locals are
    // initialized, before the outer class-statement binding is stored.
    try s.emitLeaveScope(parsed.private_scope_level);
    try s.emitLeaveScope(parsed.outer_scope_level);
    if (class_decl_local_idx) |local_idx| {
        // qjs js_parse_class: store the completed class into its
        // containing declaration binding while retaining the value.
        try Emitter.opU16(s, opcode.op.set_loc, local_idx);
    } else if (!top_level_class_binding) {
        return Error.ParserInvariant;
    }
    if (top_level_class_binding) {
        try s.emitScopePutVarInit(class_name);
    } else {
        // qjs js_parse_class: a local class declaration has no
        // expression result after its binding store.
        try Emitter.op(s, opcode.op.drop);
    }
    try typescript.emitNamespaceExportIfExported(s, class_name);
}

/// Class expression: same lowering, leaving the constructor as the value
/// and a set_class_name marker for named evaluation.
fn emitClassExpression(s: *State, class_name: ?Atom, parsed: *ParsedClass) Error!void {
    // Anonymous classes begin unnamed. Named-evaluation sites patch
    // this define_class through the trailing set_class_name marker;
    // inferred names must not travel through the function entry name or
    // become the default constructor FunctionBytecode name.
    const expr_name_atom = class_name orelse atom_module.ids.empty_string;
    if (!parsed.has_extends) {
        // qjs js_parse_class: a base class expression supplies
        // undefined as the heritage operand.
        try Emitter.op(s, opcode.op.undefined);
    }
    // qjs js_parse_class: establish the hidden initializer local's TDZ
    // before defining the class expression.
    try Emitter.opU16(s, opcode.op.set_loc_uninitialized, parsed.fields_init_local_idx);
    try emitClassDefineOperands(s, parsed.constructor_cpool_idx);
    const define_builder = s.activeBuilder();
    const define_class_pos = define_builder.code_len;
    const define_class_atom_index = define_builder.atom_len;
    // qjs js_parse_class: define the expression's class object
    // with its syntactic name (or the anonymous empty placeholder)
    // and heritage flag.
    try Emitter.opAtomU8(s, opcode.op.define_class, expr_name_atom, if (parsed.has_extends) 1 else 0);
    try emitClassFieldsInitLocalInitFromClassStack(s, parsed.fields_init_local_idx, parsed.fields_init_child_index);
    try emitClassPrivateBrands(s, .{ .instance = parsed.instance_private_brand_needed, .static_ = parsed.static_private_brand_needed });
    // qjs js_parse_class: splice the expression's
    // deferred runtime block after define_class.
    try Emitter.spliceSegment(s, &parsed.runtime_seg);
    // Same TDZ as the declaration path: computed names in the spliced
    // body must observe an uninitialized class-name binding.
    if (parsed.name_local_idx) |local_idx| try emitClassLocalInitFromClassStack(s, local_idx);
    // qjs js_parse_class: drop the prototype while retaining the
    // constructor as the class expression value.
    try Emitter.op(s, opcode.op.drop);
    try emitClassStaticInitCall(s, parsed.static_init_child_index);
    // Like QuickJS js_parse_class, leave both inner class scopes only
    // after their deferred initialization and static runtime work.
    try s.emitLeaveScope(parsed.private_scope_level);
    try s.emitLeaveScope(parsed.outer_scope_level);
    if (class_name == null) {
        // qjs cannot append a runtime set_name here: static
        // initializers have already run by then. Preserve the exact
        // parser marker shape so setObjectName can patch the earlier
        // define_class at compile time and resolve_variables can erase
        // the marker either way.
        const marker_pos = define_builder.code_len;
        const marker_after_opcode = std.math.add(u32, marker_pos, 1) catch return Error.BytecodeOverflow;
        if (marker_after_opcode <= define_class_pos) return Error.ParserInvariant;
        try Emitter.opU32(s, opcode.op.set_class_name, marker_after_opcode - define_class_pos);
        s.last_class_name_patch = .{
            .builder = define_builder,
            .define_class_pos = define_class_pos,
            .atom_index = define_class_atom_index,
            .marker_pos = marker_pos,
        };
    }
}
fn appendClassFieldInitCallToFunctionDef(
    fd: *function_def_mod.FunctionDef,
    this_idx: u16,
) Error!void {
    // qjs emit_class_field_init reads `this`
    // through a phase-1 scope_get_var; resolve_scope_var lowers that to
    // get_loc_check only when the binding is lexical, which add_var_this
    // grants exclusively to derived-class
    // constructors (lowering arm quickjs.c). The base default
    // constructor's `this` is a plain var, so qjs reads it with get_loc
    // and resolve_labels shortens that to get_loc0. Emit the long form
    // here (short-slot ids live in the phase-1 temp overlap range) with a
    // long-form if_false: resolve_labels remaps its absolute target and
    // re-shortens the jump after get_loc shrinks to get_loc0. A raw
    // if_false8 relative operand is never remapped, so it must not span
    // instructions whose lowered size can change.
    const this_read_op: u8 = if (fd.is_derived_class_constructor)
        opcode.op.get_loc_check
    else
        opcode.op.get_loc;
    // qjs emit_class_field_init: the skip target is a
    // LabelId bound at the shared drop (legacy absolute base+20). The only
    // callers run after `ensureBuilderForFd`, so the builder always exists.
    const v2b = fd.builder orelse return Error.ParserInvariant;
    try v2b.emitAtomOpU16Owned(opcode.op.scope_get_var, atom_class_fields_init, @intCast(fd.scope_level));
    try v2b.emitOp(opcode.op.dup);
    const skip = try v2b.newLabel();
    try v2b.emitJump(opcode.op.if_false, skip);
    try v2b.emitOpU16(this_read_op, this_idx);
    try v2b.emitOp(opcode.op.swap);
    try v2b.emitOpU16(opcode.op.call_method, 0);
    try v2b.bindLabel(skip);
    v2b.invalidateLastOpcode();
    try v2b.emitOp(opcode.op.drop);
}

fn appendDefaultClassConstructor(s: *State, name_atom: Atom) Error!u16 {
    const parent_fd = s.curFunc();
    const child_fd = try functions.newChildFunctionDef(s, parent_fd, name_atom, s.currentSourcePosition());
    errdefer s.discardFunctionDef(child_fd);
    child_fd.is_strict_mode = true;
    child_fd.func_type = if (s.class.has_extends) .derived_class_constructor else .class_constructor;
    child_fd.func_kind = .normal;
    child_fd.has_arguments_binding = s.class.has_extends;
    child_fd.arguments_allowed = s.class.has_extends;
    child_fd.has_this_binding = true;
    child_fd.has_home_object = true;
    // zjs currently also uses this flag for constructibility; keep it set
    // until those two contracts are split.
    child_fd.has_prototype = true;
    child_fd.is_derived_class_constructor = s.class.has_extends;
    child_fd.new_target_allowed = true;
    child_fd.super_allowed = true;
    child_fd.super_call_allowed = s.class.has_extends;
    _ = try child_fd.appendScope(-1);
    const body_scope = try child_fd.appendScope(0);
    child_fd.body_scope = body_scope;
    child_fd.scope_level = body_scope;
    try s.ensureBuilderForFd(child_fd);
    // Pinned qjs default base constructors enter through OP_check_ctor.
    // Default derived constructors use OP_init_ctor below, whose handler
    // performs the new.target gate while initializing derived state.
    const v2b = child_fd.builder.?;
    if (!s.class.has_extends) {
        // qjs js_parse_class_default_ctor: a base
        // default constructor first verifies construct invocation.
        try v2b.emitOp(opcode.op.check_ctor);
    }
    // qjs js_parse_class_default_ctor: enter the synthetic constructor
    // body scope through the child builder without a source marker.
    try v2b.emitOpU16(opcode.op.enter_scope, @intCast(body_scope));
    const this_idx = try child_fd.ensureThisBinding();
    if (s.class.has_extends) {
        // qjs js_parse_class_default_ctor: initialize
        // derived-constructor state and its checked this binding.
        try v2b.emitOp(opcode.op.init_ctor);
        try v2b.emitOpU16(opcode.op.put_loc_check_init, this_idx);
        try appendClassFieldInitCallToFunctionDef(child_fd, this_idx);
        // qjs js_parse_class_default_ctor ends with emit_return(s, FALSE)
        //; the derived arm
        // reads `this` with scope_get_var_checkthis so an uninitialized
        // ReferenceError is raised in the caller context, lowered to
        // get_loc_checkthis.
        // qjs js_parse_class_default_ctor: return the initialized
        // derived this value after running instance field setup.
        try v2b.emitOpU16(opcode.op.get_loc_checkthis, this_idx);
        try v2b.emitOp(opcode.op.@"return");
    } else {
        try appendClassFieldInitCallToFunctionDef(child_fd, this_idx);
        // qjs js_parse_class_default_ctor: a base default constructor
        // completes with return_undef after instance field setup.
        try v2b.emitOp(opcode.op.return_undef);
    }
    const cpool_idx: u16 = @intCast(try parent_fd.appendCpool(JSValue.undefinedValue()));
    child_fd.parent_cpool_idx = cpool_idx;
    try parent_fd.addChild(child_fd);
    return cpool_idx;
}
