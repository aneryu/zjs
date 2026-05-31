// The canonical ThrowTypeError intrinsic marker is internal metadata.
"use strict";

print("__zjs_throw_type_error_intrinsic" in globalThis);
print(Object.getOwnPropertyDescriptor(globalThis, "__zjs_throw_type_error_intrinsic") === undefined);

globalThis.__zjs_throw_type_error_intrinsic = function() { return 1; };
print("__zjs_throw_type_error_intrinsic" in globalThis);
print(delete globalThis.__zjs_throw_type_error_intrinsic);
print("__zjs_throw_type_error_intrinsic" in globalThis);

var thrower = Object.getOwnPropertyDescriptor(Function.prototype, "arguments").get;

print(typeof thrower);
print("__zjs_throw_type_error_function_proto" in thrower);
print(Object.getOwnPropertyDescriptor(thrower, "__zjs_throw_type_error_function_proto") === undefined);

var assignType = "none";
try {
  thrower.__zjs_throw_type_error_function_proto = false;
} catch (e) {
  assignType = e.name;
}
print(assignType);
print("__zjs_throw_type_error_function_proto" in thrower);
print(delete thrower.__zjs_throw_type_error_function_proto);

var threw = false;
try {
  thrower();
} catch (e) {
  threw = e instanceof TypeError;
}
print(threw);
