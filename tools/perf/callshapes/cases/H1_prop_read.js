// H1: own data property read.
var N = 40000000;
function main(n) {
    var o = { x: 1, y: 2 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += o.x;
    }
    return s;
}
print(main(N));
