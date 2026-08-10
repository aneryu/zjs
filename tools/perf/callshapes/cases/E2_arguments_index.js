// E2: arguments[0] on a mapped arguments object.
var N = 5000000;
function main(n) {
    function e(a, b) { return arguments[0]; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += e(1, 2);
    }
    return s;
}
print(main(N));
