var objects = [
  { a: 1, b: 2 },
  { b: 2, a: 1 },
  { c: 3, a: 1, b: 2 },
];
var sum = 0;
for (var i = 0; i < 1000000; i++) {
  sum += objects[i % 3].a;
}
print(sum);
