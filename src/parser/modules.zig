//! Modules: import/export syntax and the module record.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const JSValue = @import("../core/value.zig").JSValue;
const bytecode_module = bytecode.module;
const tok = root.token;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
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
/// Mirrors `js_parse_import` in quickjs.c
pub fn parseImport(s: *State) Error!void {
    try s.advance();
    var default_local_name: ?Atom = null;

    // TypeScript `import type ...`: no runtime import at all.
    if (s.isIdent("type") and try typescript.tsImportTypeModifier(s)) {
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
        const local_name = try expectImportBinding(s);
        default_local_name = local_name;

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
        const local_name = try expectImportBinding(s);
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
        defer imports.deinit(s.scratch);
        try s.advance();
        while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
            // TypeScript `import { type X }`: the specifier is erased.
            var type_only = false;
            if (s.isIdent("type") and try typescript.tsSpecifierTypeModifier(s)) {
                try s.advance();
                type_only = true;
            }
            // Import name (identifier or string)
            if (!isModuleNameToken(s.peekKind())) {
                return s.failExpectedDescription("import name");
            }
            const import_name_was_string = s.peekKind() == .string;
            // Only an IdentifierName that is also an Identifier can bind
            // without `as`: `import { if }` is an error.
            const import_name_is_binding = identifiers.isIdentifierLikeToken(s) and
                !identifiers.identifierLikeHasInvalidEscapeForBinding(s);
            const import_name = try moduleImportNameAtom(s);
            try s.advance();

            // Optional 'as' for renaming
            var local_name: Atom = undefined;
            if (s.isIdent("as")) {
                try s.advance();
                local_name = try expectImportBinding(s);
            } else if (import_name_was_string) {
                return s.failExpectedDescription("'as'");
            } else {
                if (!import_name_is_binding) return s.failExpectedDescription("'as'");
                local_name = import_name;
                try validateModuleImportBindingName(s, local_name);
            }

            if (!type_only) {
                try imports.append(s.scratch, .{
                    .import_name = import_name,
                    .local_name = local_name,
                });
            }

            if (s.peekKind() != .comma) break;
            try s.advance();
        }
        try s.expectToken(.rbrace);
        // Even when every specifier is `type`, the module is still loaded
        // (verbatimModuleSyntax keeps `import {} from "m"`); only a whole
        // `import type` declaration is elided.
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

fn expectImportBinding(s: *State) Error!Atom {
    if (s.peekKind() != .ident) return s.failExpectedDescription("binding name");
    const local_name = s.token.payload.ident.atom;
    try validateModuleImportBindingName(s, local_name);
    try s.advance();
    return local_name;
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
    return false;
}

fn rejectDuplicateExport(s: *State, record: *const bytecode_module.Record, export_name: Atom) Error!void {
    if (moduleHasExportName(record, export_name)) {
        return s.failNamed("duplicate export '{s}'", "duplicate export", export_name);
    }
}

pub fn addModuleExportName(s: *State, export_name: Atom, local_name: Atom) Error!void {
    const record = s.ensureModule();
    try rejectDuplicateExport(s, record, export_name);
    try record.addExport(export_name, local_name);
}

/// An exported enum or namespace may merge with an earlier exported
/// declaration of the same name (class, function, enum or namespace): that
/// export already names the one merged binding.
fn addMergeableModuleExportName(s: *State, name: Atom) Error!void {
    const record = s.ensureModule();
    for (record.exports) |entry| {
        if (entry.export_name == name and entry.local_name == name) return;
    }
    try addModuleExportName(s, name, name);
}

pub fn validateModuleLocalExports(s: *State) Error!void {
    if (s.module_record == null) return;
    const record = &s.module_record.?;
    var index: usize = 0;
    while (index < record.exports.len) {
        const local_name = record.exports[index].local_name;
        if (identifiers.hasKnownBinding(s, local_name)) {
            index += 1;
        } else if (std.mem.indexOfScalar(Atom, s.ts_type_names.items, local_name) != null) {
            try record.removeExport(index);
        } else {
            return s.failNamed("export '{s}' is not defined", "export is not defined", local_name);
        }
    }
}

fn addModuleImportAttribute(s: *State, request_index: u32, key: Atom, value: Atom) Error!void {
    const record = s.ensureModule();
    for (record.import_attributes) |entry| {
        if (entry.request_index == request_index and entry.key == key)
            return s.failExpectedDescription("unique import attribute key");
    }
    // AllImportAttributesSupported: the host supports only `type`. The spec
    // reports this while loading; failing at parse is observably the same
    // (the module never evaluates) and names the key at its source position.
    if (key != atom_module.ids.type_) {
        const key_name = s.atoms.name(key) orelse return error.ParserInvariant;
        var message_buffer: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buffer, "import attribute '{s}' is not supported", .{key_name}) catch
            "import attribute is not supported";
        return s.failWithMessage(null, message);
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
    const record = s.ensureModule();
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

const IndirectExportKind = enum { named, namespace };

fn addModuleIndirectExport(
    s: *State,
    request_index: u32,
    export_name: Atom,
    import_name: Atom,
    kind: IndirectExportKind,
) Error!void {
    const record = s.ensureModule();
    try rejectDuplicateExport(s, record, export_name);
    try record.addIndirectExport(request_index, export_name, import_name, kind == .namespace);
}

fn addModuleStarExport(s: *State, request_index: u32) Error!void {
    try s.ensureModule().addStarExport(request_index);
}

fn addModuleRequestFromCurrentString(s: *State) Error!u32 {
    const module_name = try moduleStringAtom(s);
    const record = s.ensureModule();
    return try record.addRequest(module_name);
}

fn moduleStringAtom(s: *State) Error!Atom {
    if (s.peekKind() != .string) return s.failExpectedDescription("module string");
    return try s.atoms.internString(s.token.payload.str.bytes);
}

pub fn isModuleNameToken(kind: tok.Kind) bool {
    return kind == .ident or kind == .string or kind.isKeyword();
}

/// The current module import/export name. Identifier tokens hand back their
/// borrowed id and string names are freshly interned; either way the
/// enclosing `CompileAtomScope` is the root, so the caller does not free.
/// A string ModuleExportName must be well-formed Unicode (§16.2.1.1): the
/// WTF-8 bytes of a lone surrogate fail strict UTF-8 validation.
fn moduleImportNameAtom(s: *State) Error!Atom {
    const kind = s.peekKind();
    if (kind == .ident) return s.token.payload.ident.atom;
    if (kind.isKeyword()) return kind.keywordAtom();
    if (!std.unicode.utf8ValidateSlice(s.token.payload.str.bytes)) {
        return s.failWithMessage(null, "module export name must be well-formed Unicode");
    }
    return try moduleStringAtom(s);
}

/// Parse export statement
/// Mirrors `js_parse_export` in quickjs.c
pub fn parseExport(s: *State) Error!void {
    try s.advance();

    const next_tok = s.peekKind();

    // TypeScript export forms.
    if (next_tok == .assign) {
        return s.failWithMessage(null, "'export =' is not supported; use ESM export");
    }
    if (s.isIdent("as") and try typescript.tsPeekNextIsIdent(s, "namespace", false)) {
        // `export as namespace X;` (UMD global): type-level only.
        try s.advance();
        try s.advance();
        if (!identifiers.isIdentifierLikeToken(s)) return s.failExpectedDescription("namespace name");
        try s.advance();
        _ = try s.expectSemicolon();
        return;
    }
    if (s.isIdent("type")) {
        const after_type_peek = try s.peekNext();
        const after_type = after_type_peek.kind;
        const has_lt = after_type_peek.line_terminator;
        if (after_type == .lbrace or after_type == .star) {
            try s.advance();
            return typescript.tsSkipTypeOnlyExport(s);
        }
        if (!has_lt and typescript.tsKindIsIdentifierLike(after_type)) return typescript.tsParseTypeAliasDeclaration(s);
    }
    if (next_tok == .kw_interface and try typescript.tsDeclarationStart(s) == .interface) return typescript.tsParseInterfaceDeclaration(s);
    if (try typescript.tsDeclarationStart(s) == .ambient) return typescript.tsParseAmbientDeclaration(s);
    if (s.isIdent("abstract") and try nextOnSameLineIs(s, .kw_class)) {
        try s.advance();
        return parseExportedClass(s, false);
    }
    if (next_tok == .kw_enum or (next_tok == .kw_const and try s.peekNextKind() == .kw_enum)) {
        if (next_tok == .kw_const) try s.advance();
        try typescript.parseEnumDeclaration(s);
        const name_atom = s.last_declared_atom orelse return Error.ParserInvariant;
        try addMergeableModuleExportName(s, name_atom);
        return;
    }
    if (try typescript.tsDeclarationStart(s) == .namespace) {
        try typescript.parseNamespaceDeclaration(s);
        const name_atom = s.last_declared_atom orelse return Error.ParserInvariant;
        try addMergeableModuleExportName(s, name_atom);
        return;
    }
    if (next_tok == .kw_import) {
        // `export import x = A.B;`
        if (!try typescript.tsImportAliasAhead(s)) return s.failExpectedDescription("import alias");
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
    if (next_tok == .ident and s.isIdent("async") and try nextOnSameLineIs(s, .kw_function)) {
        try s.advance(); // consume async
        return parseExportedFunction(s, .async, source_start, false);
    }
    return s.failExpectedDescription("export declaration");
}

/// `async function` / `abstract class` modifiers apply only with no line
/// terminator before the keyword ([no LineTerminator here]).
fn nextOnSameLineIs(s: *State, kind: tok.Kind) Error!bool {
    const next = try s.peekNext();
    return next.kind == kind and !next.line_terminator;
}

/// `export default <class | function | async function | expression>`.
fn parseExportDefault(s: *State) Error!void {
    try s.advance();
    if (s.isIdent("abstract") and try nextOnSameLineIs(s, .kw_class)) try s.advance();
    if (s.peekKind() == .kw_interface and try typescript.tsDeclarationStart(s) == .interface) {
        return typescript.tsParseInterfaceDeclaration(s);
    }
    const source_start = s.currentFunctionSourceStart();
    switch (s.peekKind()) {
        .kw_class => return parseExportedClass(s, true),
        .kw_function => return parseExportedFunction(s, .normal, source_start, true),
        .ident => if (s.isIdent("async") and try nextOnSameLineIs(s, .kw_function)) {
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
    const name_atom = try exportDefaultFunctionName(s);
    if (is_default and name_atom == null) {
        try functions.parseAnonymousDefaultFunctionDecl(s, func_kind, source_start);
        if (s.ts_last_decl_was_signature) return;
        return addModuleExportName(s, atom_default, atom_star_default);
    }
    try functions.parseFunctionDecl(s, func_kind, source_start);
    if (s.ts_last_decl_was_signature) return;
    if (name_atom) |name| try addModuleExportName(s, if (is_default) atom_default else name, name);
}

/// `export [default] class [name]`; an anonymous default class is stored
/// through the `*default*` binding like a default expression.
fn parseExportedClass(s: *State, is_default: bool) Error!void {
    if (is_default and !try hasExportDefaultClassName(s)) {
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
    defer export_specs.deinit(s.scratch);
    var saw_type_only_specifier = false;
    try s.advance();
    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        // TypeScript `export { type X }`: the specifier is erased.
        var type_only = false;
        if (s.isIdent("type") and try typescript.tsSpecifierTypeModifier(s)) {
            try s.advance();
            type_only = true;
            saw_type_only_specifier = true;
        }
        // Export name (identifier or string)
        if (!isModuleNameToken(s.peekKind())) {
            return s.failExpectedDescription("export name");
        }
        const local_name_was_string = s.peekKind() == .string;
        const local_name = try moduleImportNameAtom(s);
        var export_name = local_name;
        try s.advance();

        // Optional 'as' for renaming
        if (s.isIdent("as")) {
            try s.advance();
            if (!isModuleNameToken(s.peekKind())) {
                return s.failExpectedDescription("export name");
            }
            export_name = try moduleImportNameAtom(s);
            try s.advance();
        }

        if (!type_only) {
            try export_specs.append(s.scratch, .{
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
        // Every specifier was type-only: nothing is exported, but a `from`
        // module is still loaded and evaluated (`export {} from "m"`), as for
        // `import { type X } from "m"`.
        if (s.isIdent("from")) _ = try parseFromClause(s);
        _ = try s.expectSemicolon();
        return;
    }
    // Optional from clause for re-export
    if (s.isIdent("from")) {
        const request_index = try parseFromClause(s);
        for (export_specs.items) |entry| {
            try addModuleIndirectExport(s, request_index, entry.export_name, entry.import_name, .named);
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
        export_name = try moduleImportNameAtom(s);
        try s.advance();
    }
    const request_index = try parseFromClause(s);
    if (is_namespace) {
        try addModuleIndirectExport(s, request_index, export_name, atom_star, .namespace);
    } else {
        try addModuleStarExport(s, request_index);
    }
    _ = try s.expectSemicolon();
    return;
}

/// The declaration name that follows the `function` keyword, or null when
/// the declaration is anonymous. The scan token interning the name is freed
/// by this function's own `defer`, but post-TGC S3-c the id itself stays
/// rooted by the enclosing `CompileAtomScope`, so it is borrowed, not owned:
/// the caller does not free. Same contract as `moduleImportNameAtom`.
fn exportDefaultFunctionName(s: *State) Error!?Atom {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    // The position restore must be armed before the fallible scan: `nextInto()`
    // moves `pos` past the peeked token before it can fail (the identifier
    // atom is interned last, quickjs.c mirror at parser.zig lexIdentifier),
    // so a failure that escaped this frame with the restore still unarmed
    // would leave the caller parsing from mid-token - `export function f()`
    // would resume on `(` and report a spurious SyntaxError instead of
    // letting the allocation failure propagate.
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = try lookahead.peekAhead(s) orelse return null;
    defer s.lex.freeToken(&first);
    if (first.kind == .star) {
        var second = try lookahead.peekAhead(s) orelse return null;
        defer s.lex.freeToken(&second);
        if (second.kind == .ident) return second.payload.ident.atom;
        return null;
    }
    if (first.kind == .ident) return first.payload.ident.atom;
    return null;
}

/// Return whether `export default class` has a declaration name. The
/// lookahead token is released here; `parseClass` returns the real owner.
fn hasExportDefaultClassName(s: *State) Error!bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    // Same ordering contract as `exportDefaultFunctionName`: arm the
    // position restore before the fallible peek.
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var name = try lookahead.peekAhead(s) orelse return false;
    defer s.lex.freeToken(&name);
    return name.kind == .ident;
}

/// Parse from clause: from 'module'
/// Mirrors `js_parse_from_clause` in quickjs.c
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
/// Mirrors `js_parse_with_clause` in quickjs.c
fn parseWithClause(s: *State, request_index: u32) Error!void {
    try s.advance();
    try s.expectToken(.lbrace);

    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        // AttributeKey : IdentifierName | StringLiteral (reserved words too).
        const key_kind = s.peekKind();
        if (key_kind != .ident and key_kind != .string and !key_kind.isKeyword()) {
            return s.failExpectedDescription("import attribute key");
        }
        const key_atom = if (key_kind == .ident)
            s.token.payload.ident.atom
        else if (key_kind.isKeyword())
            key_kind.keywordAtom()
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
