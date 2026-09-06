// N7: Function.prototype.apply with a hoisted one-element array.
var N = 25000000;
function main(n) {
    function f(x) { return x; }
    var args = [0];
    var s = 0;
    for (var i = 0; i < n; i++) { args[0] = i; s += f.apply(null, args); }
    return s;
}
print(main(N));
