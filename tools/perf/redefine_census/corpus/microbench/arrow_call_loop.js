const f = (a, b) => a + b;
let s = 0;
for (let i = 0; i < 500000; i++) s += f(i, 1);
print(s);
