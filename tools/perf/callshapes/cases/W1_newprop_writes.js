// W1: three NEW own data property writes on a fresh object per iteration.
// Every store misses the resident put_field own probe and takes the cold
// add-property path (own miss, prototype walk, shape transition) -- the
// RayTrace new-property write shape without the constructor machinery.
// (W1 - W0) / 3 prices one new-property put_field.
var N = 5000000;
function main(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = {};
        o.x = 1;
        o.y = 2;
        o.z = 3;
        s += i;
    }
    return s;
}
print(main(N));
