// S1: two REFCOUNTED object-literal fields ({left:o,right:o}) on a fresh
// object per iteration -- the splay node-construction shape purified.
// Pre-knife, vm_literal.zig's defineFieldFast bounced every refcounted value
// to the 5-layer cold publish chain; qjs CASE(OP_define_field)
// (quickjs.c:19269) has no value-form gate. (S1 - W0) / 2 prices one
// refcounted literal field define; contrast with (W1 - W0) / 3 for the
// non-refcounted new-property write.
var N = 5000000;
function main(n) {
    var left = { d: 1 };
    var right = { d: 2 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = { left: left, right: right };
        s += i;
    }
    return s;
}
print(main(N));
