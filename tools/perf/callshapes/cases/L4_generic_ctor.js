// L4: three new own properties from a constructor that does NOT match zjs's
// simple-field construct pattern (the local `t` puts var_count above the
// pattern's limit), so both engines run a real constructor frame. Pairs with
// L4p to price prototype shadowing on the generic route, with the construct
// fast path out of the picture in both halves.
var N = 5000000;
function main(n) {
    function Three(a, b, c) { var t = a; this.x = t; this.y = b; this.z = c; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Three(1, 2, 3);
        s += p.x;
    }
    return s;
}
print(main(N));
