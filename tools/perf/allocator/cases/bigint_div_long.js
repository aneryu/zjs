// 200,000 8-limb-over-4-limb divisions. Operands are built once; each iteration
// overwrites the result so operand width never grows.
let n = 0n;
for (let i = 0; i < 8; i++) n = (n << 64n) | 0xFFFFFFFFFFFFFFFFn;
let d = 0n;
for (let i = 0; i < 4; i++) d = (d << 64n) | 0x123456789ABCDEFn;
let acc = 0n;
for (let i = 0; i < 200000; i++) acc = n / d;
print(String(acc).length);
