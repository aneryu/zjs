// Map/Set smoke tests
const map = new Map();
map.set("key", "value");
console.log(map.get("key"));
console.log(map.has("key"));
console.log(map.size);
map.delete("key");
map.clear();

const set = new Set();
set.add(1);
console.log(set.has(1));
console.log(set.size);
set.delete(1);
set.clear();

const weakMap = new WeakMap();
console.log(typeof weakMap);
console.log(weakMap.set);
console.log(weakMap.get);
console.log(weakMap.has);
console.log(weakMap.delete);

const weakSet = new WeakSet();
console.log(typeof weakSet);
console.log(weakSet.add);
console.log(weakSet.has);
console.log(weakSet.delete);

const optionalMap = new Map();
console.log(optionalMap.set() === optionalMap);
console.log(optionalMap.has(undefined));
console.log(optionalMap.get(undefined));
optionalMap.set("missing");
console.log(optionalMap.has("missing"));
console.log(optionalMap.get("missing"));
console.log(optionalMap.delete());

const optionalSet = new Set();
console.log(optionalSet.add() === optionalSet);
console.log(optionalSet.has(undefined));
console.log(optionalSet.delete());

const optionalWeakKey = {};
const optionalWeakMap = new WeakMap();
console.log(optionalWeakMap.set(optionalWeakKey) === optionalWeakMap);
console.log(optionalWeakMap.get(optionalWeakKey));
console.log(optionalWeakMap.has());
console.log(optionalWeakMap.delete());

const optionalWeakSet = new WeakSet();
console.log(optionalWeakSet.add(optionalWeakKey) === optionalWeakSet);
console.log(optionalWeakSet.has());
console.log(optionalWeakSet.delete());

let mapIteratorNextArgs;
new Map({
  [Symbol.iterator]() { return this; },
  next() {
    mapIteratorNextArgs = arguments.length;
    return { done: true };
  }
});
console.log(mapIteratorNextArgs);

let mapPrimitiveIteratorThis;
Object.defineProperty(Number.prototype, Symbol.iterator, {
  value() {
    "use strict";
    mapPrimitiveIteratorThis = typeof this;
    return { next() { return { done: true }; } };
  },
  configurable: true
});
new Map(0);
delete Number.prototype[Symbol.iterator];
console.log(mapPrimitiveIteratorThis);

console.log(new Set("aba").size);
