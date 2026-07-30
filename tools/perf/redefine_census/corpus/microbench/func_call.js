function f(x) { return x + 1; }
let sum = 0;
for (let i = 0; i < 60000; i++) sum += f(i);
print(sum);
