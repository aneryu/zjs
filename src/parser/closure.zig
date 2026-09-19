//! Parse-time views over a `FunctionDef`'s bindings that the parser
//! consults while emitting phase-1 name+scope bytecode. Closure capture
//! itself (the QuickJS `resolve_scope_var` walk, including the
//! demand-created `arguments` / self-binding / arrow `this` locals) runs
//! in `resolve_variables` after the whole function tree is parsed.

const function_def_mod = @import("parse_state.zig").function_def_mod;
const Atom = @import("parse_state.zig").Atom;

pub fn hasVisibleCurrentBinding(
    fd: *const function_def_mod.FunctionDef,
    atom_id: Atom,
    scope_level: i32,
) bool {
    if (fd.findArg(atom_id) >= 0) return true;
    var index = fd.vars.len;
    while (index > 0) {
        index -= 1;
        const vd = fd.vars[index];
        if (vd.var_name == atom_id and scopeChainContains(fd, scope_level, vd.scope_level)) return true;
    }
    return false;
}

pub fn scopeChainContains(fd: *const function_def_mod.FunctionDef, start_scope: i32, target_scope: i32) bool {
    var scope_idx = start_scope;
    while (scope_idx >= 0 and @as(usize, @intCast(scope_idx)) < fd.scopes.len) {
        if (scope_idx == target_scope) return true;
        scope_idx = fd.scopes[@intCast(scope_idx)].parent;
    }
    return false;
}

pub fn findClosureVarIndex(fd: *const function_def_mod.FunctionDef, atom_id: Atom) ?u16 {
    for (fd.closure_var, 0..) |cv, idx| {
        if (cv.var_name == atom_id) return @intCast(idx);
    }
    return null;
}
