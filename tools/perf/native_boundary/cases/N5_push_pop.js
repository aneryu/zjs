// N5: two mutating array natives per iteration (push then pop).
var N = 25000000;
function main(n) {
    var a = [];
    var s = 0;
    for (var i = 0; i < n; i++) { a.push(i); s += a.pop(); }
    return s;
}
print(main(N));
