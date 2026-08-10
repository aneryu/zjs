// F: simple constructor -- two own data properties, no prototype call.
var N = 5000000;
function main(n) {
    function Pair(a, b) { this.a = a; this.b = b; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Pair(1, 2);
        s += p.a;
    }
    return s;
}
print(main(N));
