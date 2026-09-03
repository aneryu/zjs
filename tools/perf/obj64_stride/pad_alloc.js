// In-engine pad-only load: 2-property ordinary objects, the trailing-FAM cell
// S1 moved from 96 B to 80 B. `-Dzjs_obj64_s1_pad=true` restores the 96 B cell
// without widening the class-data arm. One Array holds the live set; the
// objects under measurement are `ids.object` with trailing properties.
var N = 300000;
function main(n) {
    var hold = new Array(n);
    var s = 0;
    var i;
    for (i = 0; i < n; i++) {
        hold[i] = { a: i, b: i + 1 };
        s += hold[i].a + hold[i].b;
    }
    return s;
}
print(main(N));
