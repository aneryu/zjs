// L3: constructor adding three new own data properties -- the RayTrace Vector
// shape. Every store is a fresh property on a fresh object, so each one takes
// the add-property / shape-transition path rather than overwriting a slot.
var N = 5000000;
function main(n) {
    function Three(a, b, c) { this.x = a; this.y = b; this.z = c; }
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new Three(1, 2, 3);
        s += p.x;
    }
    return s;
}
print(main(N));
