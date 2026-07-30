// The original P6-04 residue shape: 8-limb numerator over 4-limb divisor.
let n = 0n;
for (let i = 0; i < 8; i++) n = (n << 64n) | 0xFFFFFFFFFFFFFFFFn;
let d = 0n;
for (let i = 0; i < 4; i++) d = (d << 64n) | 0x123456789ABCDEFn;
let acc = 0n;
for (let i = 0; i < 2000; i++) acc = n / d;
print(String(acc).length);
