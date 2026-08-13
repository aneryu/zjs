var N = 20000000;
function main(n) {
    var s = 1, a = 3, b = 1;
    for (var i = 0; i < n; i++) { s = (s * a + b) | 0; s = (s * a + b) | 0; s = (s * a + b) | 0; s = (s * a + b) | 0; }
    return s;
}
print(main(N) !== 0 ? 1 : 0);
