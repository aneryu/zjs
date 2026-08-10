// H2: own data property write.
var N = 60000000;
function main(n) {
    var o = { x: 1, y: 2 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        o.x = i;
    }
    return o.x;
}
print(main(N));
