// G: RayTrace-style constructor -- ctor forwards arguments to a prototype
// initialize via apply.
var N = 2000000;
function main(n) {
    function C() { this.initialize.apply(this, arguments); }
    C.prototype.initialize = function (a, b) { this.a = a; this.b = b; };
    var s = 0;
    for (var i = 0; i < n; i++) {
        var p = new C(1, 2);
        s += p.a;
    }
    return s;
}
print(main(N));
