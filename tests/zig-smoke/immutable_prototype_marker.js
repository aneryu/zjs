// Immutable-prototype state is internal and not controlled by user properties.
print("__zjs_immutable_prototype" in Object.prototype);
print(Object.getOwnPropertyDescriptor(Object.prototype, "__zjs_immutable_prototype") === undefined);
Object.prototype.__zjs_immutable_prototype = false;
print(Reflect.setPrototypeOf(Object.prototype, {}));
try {
  Object.setPrototypeOf(Object.prototype, {});
  print("no throw");
} catch (e) {
  print(e.name);
}
print(delete Object.prototype.__zjs_immutable_prototype);
print(Reflect.setPrototypeOf(Object.prototype, null));
