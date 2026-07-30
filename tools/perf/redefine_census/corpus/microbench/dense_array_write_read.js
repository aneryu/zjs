const a = [];
for (let i = 0; i < 100000; i++) a[i] = i;
let s = 0;
for (let i = 0; i < a.length; i++) s += a[i];
print(s);
