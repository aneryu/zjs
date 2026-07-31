const o = { a: 1, b: 2, c: 3 };
let s = 0;
for (let i = 0; i < 1000000; i++) s += o.b;
print(s);
