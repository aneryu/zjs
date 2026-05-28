// Runtime-strict CLI script bindings stay local, matching QuickJS qjs.
function smokeGlobalFunction() {}

var d = Object.getOwnPropertyDescriptor(globalThis, "smokeGlobalFunction");
print(d === undefined);
print(typeof smokeGlobalFunction);
print(smokeGlobalFunction.name);
