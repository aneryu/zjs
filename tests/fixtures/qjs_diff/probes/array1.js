var p = new Proxy({length:3, 0:"a", 1:"b", 2:"c"}, {});
print(Array.prototype.shift.call(p), p[0], p[1], p[2], p.length);
var p2 = new Proxy({length:3, 0:"a", 1:"b", 2:"c"}, {});
Array.prototype.unshift.call(p2, "z"); print(p2[0], p2[1], p2[2], p2[3]);
