const m = new Map();
for (let i = 0; i < 10000; i++) m.set("k" + i, i);
let s = 0;
for (let i = 0; i < 10000; i++) s += m.get("k" + i);
print(s);
