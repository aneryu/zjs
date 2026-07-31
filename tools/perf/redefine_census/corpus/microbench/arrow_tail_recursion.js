const sum = (n, acc) => n === 0 ? acc : sum(n - 1, acc + n);
let s = 0;
for (let i = 0; i < 500; i++) s = sum(100, 0);
print(s);
