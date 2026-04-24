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
