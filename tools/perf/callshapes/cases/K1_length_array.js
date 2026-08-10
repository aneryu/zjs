var N = 40000000;
function main(n) {
    var a = [1, 2, 3];
    var s = 0;
    for (var i = 0; i < n; i++) { s += a.length; }
    return s;
}
print(main(N));
