var N = 20000000;
function main(n) {
    var s1=1,s2=2,s3=3,s4=4, a = 7, b = 0xFFFFF;
    for (var i = 0; i < n; i++) { s1=(s1+a)&b; s2=(s2+a)&b; s3=(s3+a)&b; s4=(s4+a)&b; }
    return s1+s2+s3+s4;
}
print(main(N) !== -1 ? 1 : 0);
