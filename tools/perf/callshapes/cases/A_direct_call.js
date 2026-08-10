// A: direct call to a local function, result discarded.
var N = 30000000;
function main(n) {
    function f(a, b) {}
    var s = 0;
    for (var i = 0; i < n; i++) {
        f(1, 2);
    }
    return s;
}
print(main(N));
