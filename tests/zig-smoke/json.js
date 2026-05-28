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

function redefine(obj, prop, value) {
  Object.defineProperty(obj, prop, { value, writable: true, configurable: true });
}

const stringToString = String.prototype.toString;
const stringValueOf = String.prototype.valueOf;
const objectToString = Object.prototype.toString;

redefine(String.prototype, "valueOf", function () { return 17; });
redefine(String.prototype, "toString", function () { return 42; });
console.log(JSON.stringify(new String(5)));
delete String.prototype.toString;
delete Object.prototype.toString;
console.log(JSON.stringify(new String(5)));
delete String.prototype.valueOf;
try {
  JSON.stringify(new String(5));
} catch (e) {
  console.log(e.name);
}

redefine(String.prototype, "toString", stringToString);
redefine(String.prototype, "valueOf", stringValueOf);
redefine(Object.prototype, "toString", objectToString);
