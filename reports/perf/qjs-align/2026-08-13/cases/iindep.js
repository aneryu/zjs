var N = 20000000;
function main(n) {
    var s1 = 1, s2 = 2, s3 = 3, s4 = 4, a = 3, b = 1;
    for (var i = 0; i < n; i++) { s1 = (s1*a+b)|0; s2 = (s2*a+b)|0; s3 = (s3*a+b)|0; s4 = (s4*a+b)|0; }
    return s1+s2+s3+s4;
}
print(main(N) !== 0 ? 1 : 0);
