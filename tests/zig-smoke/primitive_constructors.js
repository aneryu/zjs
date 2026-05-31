// Primitive constructor call vs construct semantics
console.log(typeof Number("42"));
console.log(Number("42"));
console.log(typeof new Number("42"));
console.log(new Number("42").valueOf());
console.log(typeof Boolean(0));
console.log(Boolean(0));
console.log(typeof new Boolean(1));
console.log(new Boolean(1).valueOf());
