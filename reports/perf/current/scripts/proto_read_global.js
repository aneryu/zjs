var proto = { a: 1, b: 2, c: 3, d: 4 };
var obj = Object.create(proto);
var sum = 0;
for (var i = 0; i < 1000000; i++) {
  sum += obj.a;
}
print(sum);
