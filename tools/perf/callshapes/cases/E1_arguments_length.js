// E1: arguments.length. Compare against A2 to price arguments materialization.
var N = 5000000;
function main(n) {
    function e(a, b) { return arguments.length; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += e(1, 2);
    }
    return s;
}
print(main(N));
