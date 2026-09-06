// C3: native -> JS callback with an allocated result array, Array.prototype.map over 8 elements.
var N = 5000000;
function main(n) {
    var arr = [1, 2, 3, 4, 5, 6, 7, 8];
    var s = 0;
    var cb = function (x) { return x + 1; };
    for (var i = 0; i < n; i++) { s += i + arr.map(cb)[7]; }
    return s;
}
print(main(N));
