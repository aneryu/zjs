// ctrl: loop skeleton with the accumulate every case keeps.
var N = 50000000;
function main(n) {
    var s = 0;
    for (var i = 0; i < n; i++) { s += i; }
    return s;
}
print(main(N));
