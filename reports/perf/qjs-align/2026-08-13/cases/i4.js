var N = 10000000;
function main(n) {
    var s = 12345, a = 7, b = 0xFFFFF;
    for (var i = 0; i < n; i++) { s = ((((((((s+a)&b)+a)&b)+a)&b)+a)&b); }
    return s;
}
print(main(N) !== -1 ? 1 : 0);
