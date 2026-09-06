// N4: native method on an object receiver, one string-constant argument, boolean result.
var N = 50000000;
function main(n) {
    var o = { k: 1 };
    var s = 0;
    for (var i = 0; i < n; i++) { if (o.hasOwnProperty("k")) s += i; }
    return s;
}
print(main(N));
