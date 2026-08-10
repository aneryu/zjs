// A2: direct call whose return value is consumed. Control for the E cases.
var N = 25000000;
function main(n) {
    function f(a, b) { return b; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += f(1, 2);
    }
    return s;
}
print(main(N));
