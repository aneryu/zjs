// N1m: same native, called as a method on the global Math object.
var N = 50000000;
function main(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { s += Math.abs(i); }
    return s;
}
print(main(N));
