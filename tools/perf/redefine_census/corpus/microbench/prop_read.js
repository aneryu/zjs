let obj = { a: 1, b: 2, c: 3, d: 4 };
let sum = 0;
for (let i = 0; i < 60000; i++) sum += obj.a;
print(sum);
