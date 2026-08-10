// M2: four-deep property chain off a namespace object, the shape RayTrace uses
// everywhere (`Flog.RayTracer.Vector.prototype.subtract`). Each hop is a read
// on a plain object that carries several other properties.
var N = 10000000;
function main(n) {
    var leaf = { d: 5 };
    var c = { d: 0, c2: leaf, x1: 1, x2: 2, x3: 3 };
    var b = { b1: 1, b2: 2, c: c, b3: 3 };
    var a = { a1: 1, b: b, a2: 2, a3: 3, a4: 4 };
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += a.b.c.c2.d;
    }
    return s;
}
print(main(N));
