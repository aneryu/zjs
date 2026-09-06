// N3c: String.prototype.at with a negative (wrapping) index.
var N = 50000000;
function main(n) {
    var str = "abcdefgh";
    var s = 0;
    for (var i = 0; i < n; i++) { s += str.at(-1 - (i & 7)).length; }
    return s;
}
print(main(N));
