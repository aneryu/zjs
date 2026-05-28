function report(fn) {
  try {
    fn();
  } catch (e) {
    console.log(e.name + ": " + e.message);
  }
}

report(function () { null.x; });
report(function () { undefined[0]; });
report(function () { (1)(); });
report(function () { new Array(-1); });
report(function () { Date.prototype.toISOString.call({}); });
report(function () { new Date(NaN).toISOString(); });
report(function () { class C { #x; static f(o) { return o.#x; } } C.f({}); });
report(function () { class C { #x; static f(o) { o.#x = 1; } } C.f({}); });
report(function () { class C { #x; static f(o) { return #x in o; } } C.f(null); });
report(function () { Object.keys(null); });
report(function () { Object.create(1); });
report(function () { Object.defineProperty(null, "x", { value: 1 }); });
report(function () { Object.getPrototypeOf(null); });
report(function () { Object.setPrototypeOf(null, {}); });
report(function () { Array.prototype.push.call(null, 1); });
report(function () { [1].map(1); });
report(function () { [].reduce(function (a, b) { return a + b; }); });
report(function () { String.prototype.trim.call(null); });
report(function () { "x".repeat(-1); });
report(function () { Number.prototype.toFixed.call("x"); });
report(function () { (1).toFixed(101); });
report(function () { new Promise(1); });
report(function () { Set.prototype.add.call({}, 1); });
report(function () { Map.prototype.set.call({}, 1, 2); });
report(function () { new WeakMap([[1, 2]]); });
report(function () { RegExp.prototype.exec.call({}); });
report(function () { new Uint8Array(-1); });
report(function () { function f() { return f(); } f(); });

console.log(Reflect.ownKeys(Error.prototype).sort().join(","));
console.log(Reflect.ownKeys(TypeError.prototype).sort().join(","));
console.log(Reflect.ownKeys(AggregateError.prototype).sort().join(","));
console.log(TypeError.prototype.toString === Error.prototype.toString);
console.log(new TypeError("x").toString());
