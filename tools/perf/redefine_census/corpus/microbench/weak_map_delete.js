let map = new WeakMap();
let key = {};
map.set(key, 1);
map.delete(key);
print(map.has(key));
