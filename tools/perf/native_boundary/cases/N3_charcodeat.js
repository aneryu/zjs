// N3: native method on a primitive string receiver, one int argument.
var N = 50000000;
function main(n) {
    var str = "abcdefgh";
    var s = 0;
    for (var i = 0; i < n; i++) { s += str.charCodeAt(i & 7); }
    return s;
}
print(main(N));
