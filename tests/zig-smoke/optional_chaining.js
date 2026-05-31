// Test optional chaining
const obj = { a: { b: 42 } };
print(obj?.a?.b);
print(obj?.x?.y);
const nullObj = null;
print(nullObj?.a);
print(undefined?.a);
