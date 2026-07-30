const a = { x: 1, y: 0 };
const b = { y: 0, x: 2 };
const c = { z: 0, x: 3 };
const arr = [a, b, c];
let s = 0;
for (let i = 0; i < 1000000; i++) s += arr[i % 3].x;
print(s);
