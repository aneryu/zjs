// N6: Function.prototype.call -- JS -> native trampoline -> JS, one argument.
var N = 25000000;
function main(n) {
    function f(x) { return x; }
    var s = 0;
    for (var i = 0; i < n; i++) { s += f.call(null, i); }
    return s;
}
print(main(N));
