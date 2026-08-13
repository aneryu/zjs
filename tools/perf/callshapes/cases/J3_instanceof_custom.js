// J3: instanceof whose right operand overrides Symbol.hasInstance, so the
// ordinary algorithm is never reached. What remains is the @@hasInstance
// lookup plus a JS-to-JS call, which is the control for how much of J is the
// native boundary and the ordinary body rather than the lookup.
//
// defineProperty, not assignment: Function.prototype[@@hasInstance] is
// non-writable, so a plain store silently fails in sloppy mode and the case
// would quietly measure the ordinary algorithm instead of the override.
var N = 15000000;
function main(n) {
    function C() {}
    Object.defineProperty(C, Symbol.hasInstance, {
        value: function (x) { return true; },
    });
    var o = {};
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (o instanceof C) s++;
    }
    return s;
}
print(main(N));
