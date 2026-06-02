"use strict";

// C parity: alias, accessor, proxy, and descriptor safety audits.

// 1. Read/write aliasing & descriptors
const obj = {};
Object.defineProperty(obj, 'x', {
  value: 42,
  writable: false,
  configurable: true
});
print(obj.x);
try {
  obj.x = 99; // Should throw because 'x' is read-only
} catch (e) {
  print("caught: " + e.message);
}
print(obj.x); // Should still be 42

// 2. Accessors (Getters / Setters)
let secret = 0;
const accObj = {};
Object.defineProperty(accObj, 'y', {
  get() { return secret; },
  set(val) { secret = val + 10; },
  configurable: true
});
print(accObj.y);
accObj.y = 5;
print(accObj.y);

// 3. Proxy traps
const target = { a: 1 };
const proxy = new Proxy(target, {
  get(t, prop) {
    print("trap_get: " + prop);
    return t[prop] * 10;
  },
  set(t, prop, val) {
    print("trap_set: " + prop + " = " + val);
    t[prop] = val;
    return true;
  }
});
print(proxy.a);
proxy.a = 2;
print(proxy.a);

// 4. Prototype mutation
const base = { z: 100 };
const derived = Object.create(base);
print(derived.z);
base.z = 200;
print(derived.z);
derived.z = 300; // Own property shadow
print(derived.z);
print(base.z);
