// Native dispatch metadata is internal and stable across user-visible property operations.
var f = Object.prototype.isPrototypeOf;
print("__zjs_native_name" in f);
print(Object.getOwnPropertyDescriptor(f, "__zjs_native_name") === undefined);
print(f.call(Object.prototype, {}));
f.__zjs_native_name = "notIsPrototypeOf";
print(f.call(Object.prototype, {}));
print(delete f.__zjs_native_name);
print(f.call(Object.prototype, {}));

var a = [];
print("__zjs_native_name" in Array.prototype.push);
print(Array.prototype.push.call(a, 1));
delete Array.prototype.push.__zjs_native_name;
print(Array.prototype.push.call(a, 2));
print(a.length);
