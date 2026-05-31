// RegExp accessor realm error constructors are internal metadata.
var getter = Object.getOwnPropertyDescriptor(RegExp.prototype, "source").get;

print("__zjs_realm_TypeError" in getter);
print(Object.getOwnPropertyDescriptor(getter, "__zjs_realm_TypeError") === undefined);

function Fake(message) {
  this.message = message;
}
Fake.prototype = Object.create(Error.prototype);
Fake.prototype.constructor = Fake;

getter.__zjs_realm_TypeError = Fake;
try {
  getter.call({});
} catch (e) {
  print(e.constructor === Fake);
  print(e instanceof TypeError);
}

print(delete getter.__zjs_realm_TypeError);
try {
  getter.call({});
} catch (e) {
  print(e instanceof TypeError);
}
