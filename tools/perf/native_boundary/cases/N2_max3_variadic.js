// N2: variadic native, three int arguments.
var N = 50000000;
function main(n) {
    var max = Math.max;
    var s = 0;
    for (var i = 0; i < n; i++) { s += max(i, 1, 2); }
    return s;
}
print(main(N));
