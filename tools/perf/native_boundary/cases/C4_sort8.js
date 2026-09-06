// C4: native -> JS comparator, Array.prototype.sort over 8 already-sorted elements.
var N = 2000000;
function main(n) {
    var arr = [1, 2, 3, 4, 5, 6, 7, 8];
    var s = 0;
    var cmp = function (a, b) { return a - b; };
    for (var i = 0; i < n; i++) { s += i + arr.sort(cmp)[0]; }
    return s;
}
print(main(N));
