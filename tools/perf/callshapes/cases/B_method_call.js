// B: method call o.f(1,2) -- property lookup fused with the call.
var N = 25000000;
function main(n) {
    var o = { f: function (a, b) {} };
    var s = 0;
    for (var i = 0; i < n; i++) {
        o.f(1, 2);
    }
    return s;
}
print(main(N));
