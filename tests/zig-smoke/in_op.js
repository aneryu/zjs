// Test in operator
const obj = { a: 1, b: 2 };
print("a" in obj);
print("c" in obj);
print("toString" in obj);

var numberKey = new Number();
print(numberKey in { 0: true });

var stringHintKey = new Number();
stringHintKey.toString = function() { return "baz"; };
stringHintKey.valueOf = function() { return "qux"; };
print(stringHintKey in { baz: true });
