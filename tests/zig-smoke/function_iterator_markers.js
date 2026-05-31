// Function and iterator dispatch markers are internal and stable across user properties.
function check(fn, marker, run) {
  print(marker in fn);
  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
  fn[marker] = 0;
  print(run());
  print(delete fn[marker]);
  print(run());
}

check(Function.prototype.toString, "__zjs_function_to_string", function() {
  return typeof Function.prototype.toString.call(Array.prototype.push);
});
check(Error.prototype.toString, "__zjs_error_to_string", function() {
  return Error.prototype.toString.call({ name: "E", message: "m" });
});

var constructorDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, "constructor");
var tagDesc = Object.getOwnPropertyDescriptor(Iterator.prototype, Symbol.toStringTag);

check(constructorDesc.get, "__zjs_iterator_accessor", function() {
  return constructorDesc.get.call(Iterator.prototype) === Iterator;
});
check(constructorDesc.set, "__zjs_iterator_accessor", function() {
  var receiver = Object.create(Iterator.prototype);
  var replacement = {};
  constructorDesc.set.call(receiver, replacement);
  var primitiveResult = "ok";
  try {
    constructorDesc.set.call(Object.create(Iterator.prototype), 7);
  } catch (e) {
    primitiveResult = e.name + " " + e.message;
  }
  return [
    receiver.constructor === replacement,
    Object.prototype.propertyIsEnumerable.call(receiver, "constructor"),
    primitiveResult,
  ].join(" ");
});
check(tagDesc.get, "__zjs_iterator_accessor", function() {
  return tagDesc.get.call(Iterator.prototype);
});
check(tagDesc.set, "__zjs_iterator_accessor", function() {
  var receiver = Object.create(Iterator.prototype);
  tagDesc.set.call(receiver, "CustomIterator");
  return receiver[Symbol.toStringTag];
});

check(Iterator.from, "__zjs_iterator_static", function() {
  return typeof Iterator.from([1]).next;
});

var toArray = Iterator.prototype.toArray;
check(toArray, "__zjs_iterator_method", function() {
  return toArray.call(Iterator.from([1, 2])).join(",");
});
