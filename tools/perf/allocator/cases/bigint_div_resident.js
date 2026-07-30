// bigint_div_long.js plus a retained population in the 80-byte size class --
// the class zjs's (na+1)-limb division scratch lands in. Uint8Array(72) is the
// JS-reachable shape that allocates there. 411 is deliberately not a multiple of
// the 50 blocks per arena, so the class free list keeps a partially-filled arena
// and the scratch allocation reuses a block instead of creating an arena.
// Nothing about the division itself changes.
const keep = [];
for (let i = 0; i < 411; i++) keep.push(new Uint8Array(72));
let n = 0n;
for (let i = 0; i < 8; i++) n = (n << 64n) | 0xFFFFFFFFFFFFFFFFn;
let d = 0n;
for (let i = 0; i < 4; i++) d = (d << 64n) | 0x123456789ABCDEFn;
let acc = 0n;
for (let i = 0; i < 200000; i++) acc = n / d;
print(String(acc).length + keep[410][0]);
