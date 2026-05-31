const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");

pub const ErrorKind = enum {
    test262,
    eval,
    reference,
    syntax,
    range,
};

pub fn raise(kind: ErrorKind) error{ Test262Error, EvalError, ReferenceError, SyntaxError, RangeError } {
    return switch (kind) {
        .test262 => error.Test262Error,
        .eval => error.EvalError,
        .reference => error.ReferenceError,
        .syntax => error.SyntaxError,
        .range => error.RangeError,
    };
}

pub fn assertSameValue(actual: core.Value, expected: core.Value) !core.Value {
    if (!builtins.object.sameValue(actual, expected)) return error.Test262Error;
    return core.Value.undefinedValue();
}
