// N3b: native method on a primitive string receiver returning a one-unit string.
var N = 50000000;
function main(n) {
    var str = "abcdefgh";
    var s = 0;
    for (var i = 0; i < n; i++) { s += str.charAt(i & 7).length; }
    return s;
}
print(main(N));
