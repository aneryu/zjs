// Same map() traffic, but the previous result is retained one iteration longer
// via a two-slot rotation plus a resident population, so the result array's
// size class keeps a live block across iterations.
const a = [1,2,3,4,5,6,7,8,9,10];
const keep = [];
for (let i = 0; i < 400; i++) keep.push(a.map(x => x + 1));
let out;
for (let i = 0; i < 10000; i++) out = a.map(x => x + 1);
print(out[9] + keep[399][9]);
