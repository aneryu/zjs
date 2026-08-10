var N = 40000000;
function main(n) {
    var o = { length: 3 };
    var s = 0;
    for (var i = 0; i < n; i++) { s += o.length; }
    return s;
}
print(main(N));
