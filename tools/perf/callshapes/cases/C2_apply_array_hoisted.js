// C2: f.apply(o, args) with the array hoisted -- isolates apply from allocation.
var N = 9000000;
function main(n) {
    var o = {};
    var args = [1, 2];
    function f(a, b) {}
    var s = 0;
    for (var i = 0; i < n; i++) {
        f.apply(o, args);
    }
    return s;
}
print(main(N));
