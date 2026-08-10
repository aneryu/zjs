// C: f.apply(o, [1,2]) -- includes a fresh array literal per iteration.
var N = 6000000;
function main(n) {
    var o = {};
    function f(a, b) {}
    var s = 0;
    for (var i = 0; i < n; i++) {
        f.apply(o, [1, 2]);
    }
    return s;
}
print(main(N));
