// Test instanceof operator
function Foo() {}
const foo = new Foo();
print(foo instanceof Foo);
print({} instanceof Object);
print([] instanceof Array);
print([] instanceof Object);
