// C1: native -> JS callback, Array.prototype.forEach over 8 elements (8 callbacks per iteration).
var N = 5000000;
function main(n) {
    var arr = [1, 2, 3, 4, 5, 6, 7, 8];
    var s = 0;
    var cb = function (x) { s += x; };
    for (var i = 0; i < n; i++) { s += i; arr.forEach(cb); }
    return s;
}
print(main(N));
