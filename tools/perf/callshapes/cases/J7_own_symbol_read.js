// J7: same read as J6 but the symbol-keyed property is an own property, so the
// prototype walk is removed and only the symbol-key shape lookup remains.
var N = 15000000;
function main(n) {
    var k = Symbol("k");
    var o = {};
    Object.defineProperty(o, k, { value: 1 });
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (o[k]) s++;
    }
    return s;
}
print(main(N));
