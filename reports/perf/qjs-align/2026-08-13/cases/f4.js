// 4 组 (x*a+b) = 8 条算术，共 1 次 loc 往返
var N = 10000000;
function main(n) {
    var s = 1.5, a = 1.0000001, b = 0.0000003;
    for (var i = 0; i < n; i++) { s = ((((s*a+b)*a+b)*a+b)*a+b); }
    return s;
}
print(main(N) > 0 ? 1 : 0);
