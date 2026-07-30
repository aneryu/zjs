// The P7-20 Pareto's largest single item: 10,000 result arrays, each freed
// before the next is built, plus 100,000 arrow callbacks.
const a = [1,2,3,4,5,6,7,8,9,10];
let out;
for (let i = 0; i < 10000; i++) out = a.map(x => x + 1);
print(out[9]);
