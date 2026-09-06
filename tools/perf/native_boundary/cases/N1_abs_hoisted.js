// N1: JS -> native leaf, one int argument, callee hoisted to a local.
var N = 50000000;
function main(n) {
    var abs = Math.abs;
    var s = 0;
    for (var i = 0; i < n; i++) { s += abs(i); }
    return s;
}
print(main(N));
