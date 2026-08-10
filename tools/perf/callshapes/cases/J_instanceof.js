// J: instanceof against the direct constructor.
var N = 15000000;
function main(n) {
    function Pair(a, b) { this.a = a; this.b = b; }
    var o = new Pair(1, 2);
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (o instanceof Pair) s++;
    }
    return s;
}
print(main(N));
