// C2: native -> JS callback with a return value, Array.prototype.reduce over 8 elements.
var N = 5000000;
function main(n) {
    var arr = [1, 2, 3, 4, 5, 6, 7, 8];
    var s = 0;
    var cb = function (a, x) { return a + x; };
    for (var i = 0; i < n; i++) { s += i + arr.reduce(cb, 0); }
    return s;
}
print(main(N));
