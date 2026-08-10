// M3: same read site, two receiver shapes alternating. RayTrace's hot reads
// (`shape.intersect`, `shape.material`, `info.color`) see Sphere and Plane, so
// M3 - H1 is what polymorphism at one site costs.
var N = 40000000;
function main(n) {
    function A() { this.p = 1; this.q = 2; }
    function B() { this.r = 3; this.p = 4; }
    var a = new A(), b = new B();
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = (i & 1) ? a : b;
        s += o.p;
    }
    return s;
}
print(main(N));
