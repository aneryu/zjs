// D: forwarding wrapper -- g materializes arguments then applies it.
var N = 3500000;
function main(n) {
    var o = {};
    function f(a, b) {}
    function g() { return f.apply(o, arguments); }
    var s = 0;
    for (var i = 0; i < n; i++) {
        g(1, 2);
    }
    return s;
}
print(main(N));
