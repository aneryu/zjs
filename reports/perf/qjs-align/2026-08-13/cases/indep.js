// 同样多的浮点运算，但四条独立链（OoO 可以并行）
var N = 20000000;
function main(n) {
    var s1 = 1.5, s2 = 2.5, s3 = 3.5, s4 = 4.5, a = 1.0000001, b = 0.0000003;
    for (var i = 0; i < n; i++) { s1 = s1 * a + b; s2 = s2 * a + b; s3 = s3 * a + b; s4 = s4 * a + b; }
    return s1 + s2 + s3 + s4;
}
print(main(N) > 0 ? 1 : 0);
