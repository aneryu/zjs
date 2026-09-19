//! Modules: import/export syntax and the module record.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const JSValue = @import("../core/value.zig").JSValue;
const bytecode_module = bytecode.module;
const tok = root.token;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const typescript = @import("typescript.zig");
const atom_default = parse_state.atom_default;
const atom_star_default = parse_state.atom_star_default;
const atom_star = parse_state.atom_star;
const Error = parse_state.Error;
const ParseFlags = parse_state.ParseFlags;
const ParseFunctionKind = parse_state.ParseFunctionKind;
const FunctionSourceStart = parse_state.FunctionSourceStart;
const State = parse_state.State;

const ModuleImportSpec = struct {
    import_name: Atom,
    local_name: Atom,
};

const ModuleExportSpec = struct {
    export_name: Atom,
    import_name: Atom,
    import_name_is_string: bool = false,
};

/// Parse import statement
/// Mirrors `js_parse_import` in quickjs.c:31312
pub fn parseImport(s: *State) Error!void {
    try s.advance();
    var default_local_name: ?Atom = null;

    // TypeScript `import type ...`: no runtime import at all.
    if (s.isIdent("type") and typescript.tsImportTypeModifier(s)) {
        try s.advance();
        return typescript.tsSkipTypeOnlyImport(s);
    }

    // Side-effect import: import 'module'
    if (s.peekKind() == .string) {
        const request_index = try addModuleRequestFromCurrentString(s);
        try s.advance();
        if (s.peekKind() == .kw_with) {
            try parseWithClause(s, request_index);
        }
        _ = try s.expectSemicolon();
        return;
    }

    // Default import: import x from 'module'
    if (s.peekKind() == .ident) {
        const local_name = s.token.payload.ident.atom;
        default_local_name = local_name;
        try validateModuleImportBindingName(s, local_name);
        try s.advance();

        if (s.peekKind() != .comma) {
            const request_index = try parseFromClause(s);
            try addModuleImportBinding(s, request_index, atom_default, local_name, false);
            // parseFromClause handles with clause, so expect semicolon after
            _ = try s.expectSemicolon();
            return;
        }
        try s.advance();
    }

    // Namespace import: import * as ns from 'module'
    if (s.peekKind() == .star) {
        try s.advance();
        // Expect 'as'
        if (!s.isIdent("as")) {
            return s.failExpectedDescription("'as'");
        }
        try s.advance();
        // Expect namespace identifier
        if (s.peekKind() != .ident) {
            return s.failExpectedDescription("binding name");
        }
        const local_name = s.token.payload.ident.atom;
        try validateModuleImportBindingName(s, local_name);
        try s.advance();
        const request_index = try parseFromClause(s);
        if (default_local_name) |default_name| {
            try addModuleImportBinding(s, request_index, atom_default, default_name, false);
        }
        try addModuleImportBinding(s, request_index, atom_star, local_name, true);
        _ = try s.expectSemicolon();
        return;
    }

    // Named imports: import { x, y as z } from 'module'
    if (s.peekKind() == .lbrace) {
        var imports = std.ArrayList(ModuleImportSpec).empty;
        defer freeModuleImportSpecs(s, &imports);
        var saw_type_only_specifier = false;
        try s.advance();
        while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
            // TypeScript `import { type X }`: the specifier is erased.
            var type_only = false;
            if (s.isIdent("type") and typescript.tsSpecifierTypeModifier(s)) {
                try s.advance();
                type_only = true;
                saw_type_only_specifier = true;
            }
            // Import name (identifier or string)
            if (!isModuleNameToken(s.peekKind())) {
                return s.failExpectedDescription("import name");
            }
            const import_name_was_string = s.peekKind() == .string;
            const import_name = try moduleImportNameAtom(s);
            try s.advance();

            // Optional 'as' for renaming
            var local_name: Atom = undefined;
            if (s.isIdent("as")) {
                try s.advance();
                if (s.peekKind() != .ident) {
                    return s.failExpectedDescription("binding name");
                }
                local_name = s.token.payload.ident.atom;
                try validateModuleImportBindingName(s, local_name);
                try s.advance();
            } else if (import_name_was_string) {
                return s.failExpectedDescription("'as'");
            } else {
                local_name = import_name;
                try validateModuleImportBindingName(s, local_name);
            }

            if (!type_only) {
                try imports.append(s.function.memory.allocator, .{
                    .import_name = import_name,
                    .local_name = local_name,
                });
            }

            if (s.peekKind() != .comma) break;
            try s.advance();
        }
        try s.expectToken(.rbrace);
        if (saw_type_only_specifier and imports.items.len == 0 and default_local_name == null) {
            // Every specifier was type-only: tsc elides the whole import.
            try typescript.tsSkipFromClause(s);
            _ = try s.expectSemicolon();
            return;
        }
        const request_index = try parseFromClause(s);
        if (default_local_name) |default_name| {
            try addModuleImportBinding(s, request_index, atom_default, default_name, false);
        }
        for (imports.items) |entry| {
            try addModuleImportBinding(s, request_index, entry.import_name, entry.local_name, false);
        }
        _ = try s.expectSemicolon();
        return;
    }

    return s.failExpectedDescription("import clause");
}

fn validateModuleImportBindingName(s: *State, atom_id: Atom) Error!void {
    if (identifiers.isInvalidStrictFunctionBindingName(s, atom_id)) {
        return s.failUnexpectedToken();
    }
}

fn moduleHasExportName(record: *const bytecode_module.Record, export_name: Atom) bool {
    for (record.exports) |entry| {
        if (entry.export_name == export_name) return true;
    }
    for (record.indirect_exports) |entry| {
        if (entry.export_name == export_name) return true;
    }
    for (record.star_exports) |entry| {
        if (entry.export_name != atom_star and entry.export_name == export_name) return true;
    }
    return false;
}

pub fn addModuleExportName(s: *State, export_name: Atom, local_name: Atom) Error!void {
    const record = s.function.ensureModule();
    if (moduleHasExportName(record, export_name)) return s.failExpectedDescription("unique export name");
    try record.addExport(export_name, local_name);
}

pub fn validateModuleLocalExports(s: *State) Error!void {
    const record = s.function.module_record orelse return;
    for (record.exports) |entry| {
        if (!identifiers.hasKnownBinding(s, entry.local_name)) return s.failExpectedDescription("local export binding");
    }
}

fn addModuleImportAttribute(s: *State, request_index: u32, key: Atom, value: Atom) Error!void {
    const record = s.function.ensureModule();
    for (record.import_attributes) |entry| {
        if (entry.request_index == request_index and entry.key == key)
            return s.failExpectedDescription("unique import attribute key");
    }
    try record.addImportAttribute(request_index, key, value);
}

fn addModuleImportBinding(
    s: *State,
    request_index: u32,
    import_name: Atom,
    local_name: Atom,
    is_namespace: bool,
) Error!void {
    if (identifiers.hasKnownBinding(s, local_name)) return s.failExpectedDescription("available local import binding");
    if (s.curFunc().closure_var.len > std.math.maxInt(u16)) return error.BytecodeOverflow;
    const raw_var_idx = try s.curFunc().addClosureVar(.{
        // qjs add_import: namespace imports own a MODULE_DECL slot that
        // linking fills with the namespace cell; named/default imports are
        // MODULE_IMPORT aliases of an exported binding.
        .closure_type = if (is_namespace) .module_decl else .module_import,
        .is_lexical = true,
        .is_const = true,
        .var_kind = .normal,
        .var_idx = @intCast(s.curFunc().closure_var.len),
        .var_name = local_name,
    });
    if (raw_var_idx < 0 or raw_var_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
    const record = s.function.ensureModule();
    try record.addImport(
        request_index,
        import_name,
        local_name,
        @intCast(raw_var_idx),
        is_namespace,
    );
}

fn ensureModuleDefaultExportBinding(s: *State) Error!void {
    switch (try declarations.defineVar(s, atom_star_default, .let_)) {
        .global => {},
        .local, .argument => return Error.ParserInvariant,
    }
}

fn addModuleIndirectExport(
    s: *State,
    request_index: u32,
    export_name: Atom,
    import_name: Atom,
    is_namespace: bool,
) Error!void {
    const record = s.function.ensureModule();
    if (moduleHasExportName(record, export_name)) return s.failExpectedDescription("unique export name");
    try record.addIndirectExport(request_index, export_name, import_name, is_namespace);
}

fn addModuleStarExport(s: *State, request_index: u32, export_name: Atom) Error!void {
    const record = s.function.ensureModule();
    if (export_name != atom_star and moduleHasExportName(record, export_name))
        return s.failExpectedDescription("unique export name");
    try record.addStarExport(request_index, export_name);
}

fn addModuleRequestFromCurrentString(s: *State) Error!u32 {
    const module_name = try moduleStringAtom(s);
    const record = s.function.ensureModule();
    return try record.addRequest(module_name);
}

fn moduleStringAtom(s: *State) Error!Atom {
    if (s.peekKind() != .string) return s.failExpectedDescription("module string");
    return try s.function.atoms.internString(s.token.payload.str.bytes);
}

pub fn isModuleNameToken(kind: tok.TokenKind) bool {
    return kind == .ident or kind == .string or tok.isKeyword(kind);
}

/// The current module import/export name. Identifier tokens hand back their
/// borrowed id and string names are freshly interned; either way the
/// enclosing `CompileAtomScope` is the root, so the caller does not free.
fn moduleImportNameAtom(s: *State) Error!Atom {
    const kind = s.peekKind();
    if (kind == .ident) return s.token.payload.ident.atom;
    if (tok.isKeyword(kind)) return tok.keywordAtom(kind);
    return try moduleStringAtom(s);
}

fn isWellFormedModuleString(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return false;
        if (index + width > bytes.len) return false;
        if (width == 3 and bytes[index] == 0xED and bytes[index + 1] >= 0xA0 and bytes[index + 1] <= 0xBF) {
            if (bytes[index + 2] & 0xC0 == 0x80) return false;
        }
        _ = std.unicode.utf8Decode(bytes[index .. index + width]) catch |err| switch (err) {
            error.Utf8EncodesSurrogateHalf => return false,
            else => return false,
        };
        index += width;
    }
    return true;
}

fn freeModuleImportSpecs(s: *State, imports: *std.ArrayList(ModuleImportSpec)) void {
    imports.deinit(s.function.memory.allocator);
}

fn freeModuleExportSpecs(s: *State, exports: *std.ArrayList(ModuleExportSpec)) void {
    exports.deinit(s.function.memory.allocator);
}

/// Parse export statement
/// Mirrors `js_parse_export` in quickjs.c:31090
pub fn parseExport(s: *State) Error!void {
    try s.advance();

    const next_tok = s.peekKind();

    // TypeScript export forms.
    if (next_tok == .assign) {
        return s.failWithMessage(null, "'export =' is not supported; use ESM export");
    }
    if (s.isIdent("as") and typescript.tsPeekNextIsIdent(s, "namespace", false)) {
        // `export as namespace X;` (UMD global): type-level only.
        try s.advance();
        try s.advance();
        if (!identifiers.isIdentifierLikeToken(s)) return s.failExpectedDescription("namespace name");
        try s.advance();
        _ = try s.expectSemicolon();
        return;
    }
    if (s.isIdent("type")) {
        const after_type_peek = s.peekNext();
        const after_type = after_type_peek.kind;
        const has_lt = after_type_peek.line_terminator;
        if (after_type == .lbrace or after_type == .star) {
            try s.advance();
            return typescript.tsSkipTypeOnlyExport(s);
        }
        if (!has_lt and typescript.tsKindIsIdentifierLike(after_type)) return typescript.tsParseTypeAliasDeclaration(s);
    }
    if (next_tok == .kw_interface and typescript.tsDeclarationStart(s) == .interface) return typescript.tsParseInterfaceDeclaration(s);
    if (typescript.tsDeclarationStart(s) == .ambient) return typescript.tsParseAmbientDeclaration(s);
    if (s.isIdent("abstract") and s.peekNextKind() == .kw_class) {
        try s.advance();
        return parseExportedClass(s, false);
    }
    if (next_tok == .kw_enum or (next_tok == .kw_const and s.peekNextKind() == .kw_enum)) {
        if (next_tok == .kw_const) try s.advance();
        try typescript.parseEnumDeclaration(s);
        const name_atom = s.last_declared_atom orelse return Error.ParserInvariant;
        try addModuleExportName(s, name_atom, name_atom);
        return;
    }
    if (typescript.tsDeclarationStart(s) == .namespace) {
        try typescript.parseNamespaceDeclaration(s);
        const name_atom = s.last_declared_atom orelse return Error.ParserInvariant;
        try addModuleExportName(s, name_atom, name_atom);
        return;
    }
    if (next_tok == .kw_import) {
        // `export import x = A.B;`
        if (!typescript.tsImportAliasAhead(s)) return s.failExpectedDescription("import alias");
        try s.advance();
        return typescript.tsParseImportAlias(s, true);
    }

    if (next_tok == .kw_default) return parseExportDefault(s);
    if (next_tok == .lbrace) return parseExportList(s);
    if (next_tok == .star) return parseExportStar(s);

    // export var/let/const
    if (next_tok == .kw_var or next_tok == .kw_let or next_tok == .kw_const) {
        const var_tok = next_tok;
        try s.advance();
        try statements.parseVar(s, var_tok, true, ParseFlags.default);
        _ = try s.expectSemicolon();
        return;
    }
    const source_start = s.currentFunctionSourceStart();
    if (next_tok == .kw_function) return parseExportedFunction(s, .normal, source_start, false);
    if (next_tok == .kw_class) return parseExportedClass(s, false);
    if (next_tok == .ident and s.isIdent("async") and s.peekNextKind() == .kw_function) {
        try s.advance(); // consume async
        return parseExportedFunction(s, .async, source_start, false);
    }
    return s.failExpectedDescription("export declaration");
}

/// `export default <class | function | async function | expression>`.
fn parseExportDefault(s: *State) Error!void {
    try s.advance();
    if (s.isIdent("abstract") and s.peekNextKind() == .kw_class) try s.advance();
    if (s.peekKind() == .kw_interface and typescript.tsDeclarationStart(s) == .interface) {
        return typescript.tsParseInterfaceDeclaration(s);
    }
    const source_start = s.currentFunctionSourceStart();
    switch (s.peekKind()) {
        .kw_class => return parseExportedClass(s, true),
        .kw_function => return parseExportedFunction(s, .normal, source_start, true),
        .ident => if (s.isIdent("async") and s.peekNextKind() == .kw_function) {
            try s.advance();
            return parseExportedFunction(s, .async, source_start, true);
        },
        else => {},
    }
    try expressions.parseAssignExpr(s);
    try functions.emitAnonymousDefaultName(s, atom_default);
    try bindDefaultExportValue(s);
    _ = try s.expectSemicolon();
}

/// `export [default] [async] function [name]`. A named declaration is
/// exported under its own name, or under `default`; an anonymous default
/// declaration uses the `*default*` carrier.
fn parseExportedFunction(s: *State, func_kind: ParseFunctionKind, source_start: FunctionSourceStart, is_default: bool) Error!void {
    const name_atom = exportDefaultFunctionName(s);
    if (is_default and name_atom == null) {
        try functions.parseAnonymousDefaultFunctionDecl(s, func_kind, source_start);
        return addModuleExportName(s, atom_default, atom_star_default);
    }
    try functions.parseFunctionDecl(s, func_kind, source_start);
    if (s.ts_last_decl_was_signature) return;
    if (name_atom) |name| try addModuleExportName(s, if (is_default) atom_default else name, name);
}

/// `export [default] class [name]`; an anonymous default class is stored
/// through the `*default*` binding like a default expression.
fn parseExportedClass(s: *State, is_default: bool) Error!void {
    if (is_default and !hasExportDefaultClassName(s)) {
        _ = try classes.parseClass(s, false);
        try functions.setObjectName(s, atom_default);
        return bindDefaultExportValue(s);
    }
    const name_atom = (try classes.parseClass(s, true)) orelse return Error.ParserInvariant;
    try addModuleExportName(s, if (is_default) atom_default else name_atom, name_atom);
}

/// Store the value on the stack into the module's `*default*` binding and
/// export it as `default`.
fn bindDefaultExportValue(s: *State) Error!void {
    try ensureModuleDefaultExportBinding(s);
    try s.emitScopePutVarInit(atom_star_default);
    try addModuleExportName(s, atom_default, atom_star_default);
}

/// `export { a, b as c } [from "m"]`.
fn parseExportList(s: *State) Error!void {
    var export_specs = std.ArrayList(ModuleExportSpec).empty;
    defer freeModuleExportSpecs(s, &export_specs);
    var saw_type_only_specifier = false;
    try s.advance();
    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        // TypeScript `export { type X }`: the specifier is erased.
        var type_only = false;
        if (s.isIdent("type") and typescript.tsSpecifierTypeModifier(s)) {
            try s.advance();
            type_only = true;
            saw_type_only_specifier = true;
        }
        // Export name (identifier or string)
        if (!isModuleNameToken(s.peekKind())) {
            return s.failExpectedDescription("export name");
        }
        const local_name_was_string = s.peekKind() == .string;
        if (local_name_was_string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
            return s.failUnexpectedToken();
        }
        const local_name = try moduleImportNameAtom(s);
        var export_name = local_name;
        try s.advance();

        // Optional 'as' for renaming
        if (s.isIdent("as")) {
            try s.advance();
            if (!isModuleNameToken(s.peekKind())) {
                return s.failExpectedDescription("export name");
            }
            if (s.peekKind() == .string and !isWellFormedModuleString(s.token.payload.str.bytes)) {
                return s.failUnexpectedToken();
            }
            export_name = try moduleImportNameAtom(s);
            try s.advance();
        }

        if (!type_only) {
            try export_specs.append(s.function.memory.allocator, .{
                .export_name = export_name,
                .import_name = local_name,
                .import_name_is_string = local_name_was_string,
            });
        }

        if (s.peekKind() != .comma) break;
        try s.advance();
    }
    try s.expectToken(.rbrace);

    if (saw_type_only_specifier and export_specs.items.len == 0) {
        // Every specifier was type-only: nothing is exported.
        if (s.isIdent("from")) try typescript.tsSkipFromClause(s);
        _ = try s.expectSemicolon();
        return;
    }
    // Optional from clause for re-export
    if (s.isIdent("from")) {
        const request_index = try parseFromClause(s);
        for (export_specs.items) |entry| {
            try addModuleIndirectExport(s, request_index, entry.export_name, entry.import_name, false);
        }
    } else {
        for (export_specs.items) |entry| {
            if (entry.import_name_is_string) return s.failExpectedDescription("'from'");
            try addModuleExportName(s, entry.export_name, entry.import_name);
        }
    }
    _ = try s.expectSemicolon();
    return;
}

/// `export * from "m"` / `export * as ns from "m"`.
fn parseExportStar(s: *State) Error!void {
    try s.advance();
    // Optional 'as' for namespace re-export
    var export_name = atom_star;
    var is_namespace = false;
    if (s.isIdent("as")) {
        is_namespace = true;
        try s.advance();
        if (!isModuleNameToken(s.peekKind())) {
            return s.failExpectedDescription("export name");
        }
        if (s.peekKind() == .string and !isWellFormedModuleString(s.token.payload.str.bytes)) return s.failUnexpectedToken();
        export_name = try moduleImportNameAtom(s);
        try s.advance();
    }
    const request_index = try parseFromClause(s);
    if (is_namespace) {
        try addModuleIndirectExport(s, request_index, export_name, atom_star, true);
    } else {
        try addModuleStarExport(s, request_index, export_name);
    }
    _ = try s.expectSemicolon();
    return;
}

/// The declaration name that follows the `function` keyword, or null when
/// the declaration is anonymous. The scan token interning the name is freed
/// by this function's own `defer`, but post-TGC S3-c the id itself stays
/// rooted by the enclosing `CompileAtomScope`, so it is borrowed, not owned:
/// the caller does not free. Same contract as `moduleImportNameAtom`.
fn exportDefaultFunctionName(s: *State) ?Atom {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    // The position restore must be armed before the fallible scan: `nextInto()`
    // moves `pos` past the peeked token before it can fail (the identifier
    // atom is interned last, quickjs.c mirror at parser.zig lexIdentifier),
    // so a failure that escaped this frame with the restore still unarmed
    // would leave the caller parsing from mid-token - `export function f()`
    // would resume on `(` and report a spurious SyntaxError instead of
    // letting the allocation failure propagate.
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return null;
    defer s.lex.freeToken(&first);
    if (first.val == .star) {
        var second = s.lex.next() catch return null;
        defer s.lex.freeToken(&second);
        if (second.val == .ident) return second.payload.ident.atom;
        return null;
    }
    if (first.val == .ident) return first.payload.ident.atom;
    return null;
}

/// Return whether `export default class` has a declaration name. The
/// lookahead token is released here; `parseClass` returns the real owner.
fn hasExportDefaultClassName(s: *State) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    // Same ordering contract as `exportDefaultFunctionName`: arm the
    // position restore before the fallible peek.
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var name = s.lex.next() catch return false;
    defer s.lex.freeToken(&name);
    return name.val == .ident;
}

/// Parse from clause: from 'module'
/// Mirrors `js_parse_from_clause` in quickjs.c:31039
fn parseFromClause(s: *State) Error!u32 {
    // Expect 'from' keyword
    if (!s.isIdent("from")) {
        return s.failExpectedDescription("'from'");
    }
    try s.advance();

    // Expect string literal for module name
    if (s.peekKind() != .string) {
        return s.failExpectedDescription("module string");
    }
    const request_index = try addModuleRequestFromCurrentString(s);
    try s.advance();

    // Optional with clause for import attributes
    if (s.peekKind() == .kw_with) {
        try parseWithClause(s, request_index);
    }
    return request_index;
}

/// Parse with clause for import attributes
/// Mirrors `js_parse_with_clause` in quickjs.c:30950
fn parseWithClause(s: *State, request_index: u32) Error!void {
    try s.advance();
    try s.expectToken(.lbrace);

    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        // Key (identifier or string)
        if (s.peekKind() != .ident and s.peekKind() != .string) {
            return s.failExpectedDescription("import attribute key");
        }
        const key_atom = if (s.peekKind() == .ident)
            s.token.payload.ident.atom
        else
            try moduleStringAtom(s);
        try s.advance();

        try s.expectToken(.colon);

        // JSValue (string)
        if (s.peekKind() != .string) {
            return s.failExpectedDescription("string attribute value");
        }
        const value_atom = try moduleStringAtom(s);
        try addModuleImportAttribute(s, request_index, key_atom, value_atom);
        try s.advance();

        if (s.peekKind() != .comma) break;
        try s.advance();
    }

    try s.expectToken(.rbrace);
}
