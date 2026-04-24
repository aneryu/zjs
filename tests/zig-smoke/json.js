// JSON object smoke tests
const obj = { a: 1, b: 2 };
const str = JSON.stringify(obj);
console.log(str);
const parsed = JSON.parse(str);
console.log(parsed.a);
console.log(parsed.b);
console.log(JSON.stringify({ a: undefined, b: null, c: 1 }));
console.log(JSON.stringify([undefined, null, 1]));
console.log(JSON.stringify(undefined));
console.log(JSON.stringify(NaN));
console.log(JSON.stringify(Infinity));
console.log(JSON.stringify(-Infinity));
