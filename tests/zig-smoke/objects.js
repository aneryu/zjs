const o = { a: 1, b: 2 };
print(o.a, o.b);

o.c = 3;
print(o.c);
print(Object.keys(o).join(","));
print(Object.values(o).join(","));
print(JSON.stringify(Object.entries(o)));
var keyOrder = "";
for (var k in o) keyOrder += k;
print(keyOrder);

const arr = [10, 20, 30];
print(arr[0], arr[1], arr[2]);
print(arr.length);
