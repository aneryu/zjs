// P7-61 non-target sentinel: exercises op_if_false8's inline immediate arm.
// Deliberately contains no `!` at all, so op.lnot is never executed: any move
// here is collateral from the added hot handler's effect on dispatch codegen,
// not from the cut's own semantics.
function run() {
    var t = 0;
    var a = 1;
    var b = 0;
    for (var i = 0; i < 100000000; i++) {
        if (a) t = t + 1;
        if (b) t = t + 2;
    }
    return t;
}
print(run());
