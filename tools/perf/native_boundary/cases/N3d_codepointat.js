// N3d: String.prototype.codePointAt on a BMP receiver, one int argument.
var N = 50000000;
function main(n) {
    var str = "abcdefgh";
    var s = 0;
    for (var i = 0; i < n; i++) { s += str.codePointAt(i & 7); }
    return s;
}
print(main(N));
