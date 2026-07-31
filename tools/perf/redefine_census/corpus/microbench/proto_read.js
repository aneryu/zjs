const p = { x: 1 };
const o = Object.create(p);
let s = 0;
for (let i = 0; i < 1000000; i++) s += o.x;
print(s);
