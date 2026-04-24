// C parity: `in` and `instanceof` should use property/prototype semantics.
const obj = { x: 1 };
print("x" in obj);
print("toString" in obj);
print(obj instanceof Object);
