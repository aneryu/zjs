// 串行依赖：每次运算都依赖上一次的结果
var N = 20000000;
function main(n) {
    var s = 1.5, a = 1.0000001, b = 0.0000003;
    for (var i = 0; i < n; i++) { s = s * a + b; s = s * a + b; s = s * a + b; s = s * a + b; }
    return s;
}
print(main(N) > 0 ? 1 : 0);
