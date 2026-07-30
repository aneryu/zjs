const obj = { x: 1 };
let acc = 0;
for (let i = 0; i < 2000000; i++) { obj.x = i; acc += obj.x; }
print(acc);
