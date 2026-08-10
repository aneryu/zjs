// E4: same as E1 but four mapped parameters. E4-E1 prices two extra var-refs.
var N = 5000000;
function main(n) {
    function e(a, b, c, d) { return arguments.length; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += e(1, 2, 3, 4);
    }
    return s;
}
print(main(N));
