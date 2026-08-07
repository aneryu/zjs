// Differential oracle for the native-dispatch name probes.
// Every case funnels a callable through the array/string probe cascade in a
// shape whose *name* is unusual: utf16 names, accessor `get `/`set ` names,
// `.bind` wrappers (no interned dispatch atom -> fallback path), redefined /
// deleted / throwing `name` properties, symbol-derived names, anonymous
// functions and proxies. Output must be byte-identical between the
// pre-change zjs, the post-change zjs, and (where the semantics are
// standard) qjs.
var out = [];
function t(label, fn) {
  var r;
  try {
    r = "ok " + String(fn());
  } catch (e) {
    // Only the error *name* is compared: two pre-existing zjs/qjs message-text
    // differences (`TypedArray.prototype.subarray` on a plain array, `slice` on
    // null) are unrelated to name-based dispatch and would mask real diffs.
    r = "throw " + (e && e.name ? e.name : String(e));
  }
  out.push(label + " => " + r);
}

var A = Array.prototype;
var TA = Object.getPrototypeOf(Int8Array.prototype);

// --- 1. plain native method calls through every cascade member -------------
t("arr.at", function () { return [1, 2, 3].at(1); });
t("arr.slice", function () { return [1, 2, 3].slice(1).join("|"); });
t("arr.concat", function () { return [1].concat([2]).join("|"); });
t("arr.indexOf", function () { return [1, 2].indexOf(2); });
t("arr.sort", function () { return [3, 1].sort().join("|"); });
t("arr.flat", function () { return [[1], [2]].flat().join("|"); });
t("arr.toSorted", function () { return [3, 1].toSorted().join("|"); });
t("arr.values", function () { return [1, 2].values().next().value; });
t("ta.slice", function () { return new Uint8Array([1, 2, 3]).slice(1).join("|"); });
t("ta.subarray", function () { return new Uint8Array([1, 2, 3]).subarray(1).join("|"); });
t("ta.sort", function () { return new Uint8Array([3, 1]).sort().join("|"); });
t("ta.fill", function () { return new Uint8Array(3).fill(7).join("|"); });
t("ta.set", function () { var x = new Uint8Array(3); x.set([1, 2], 1); return x.join("|"); });
t("ta.copyWithin", function () { return new Uint8Array([1, 2, 3]).copyWithin(0, 1).join("|"); });
t("ta.indexOf", function () { return new Uint8Array([1, 2]).indexOf(2); });
t("ta.reverse", function () { return new Uint8Array([1, 2]).reverse().join("|"); });
t("ta.toSorted", function () { return new Uint8Array([3, 1]).toSorted().join("|"); });
t("ta.at", function () { return new Uint8Array([1, 2]).at(1); });
t("ta.join", function () { return new Uint8Array([1, 2]).join("|"); });

// --- 2. detached natives called via .call / .apply / Reflect.apply ---------
t("detached at.call", function () { return A.at.call([1, 2], 1); });
t("detached slice.apply", function () { return A.slice.apply([1, 2, 3], [1]).join("|"); });
t("Reflect.apply subarray", function () { return Reflect.apply(TA.subarray, new Uint8Array([1, 2, 3]), [1]).join("|"); });

// --- 3. `.bind` wrappers: name becomes "bound X", no dispatch atom ---------
t("bound at", function () { return A.at.bind([1, 2])(1); });
t("bound slice", function () { return A.slice.bind([1, 2, 3])(1).join("|"); });
t("bound subarray", function () { return TA.subarray.bind(new Uint8Array([1, 2, 3]))(1).join("|"); });
t("bound sort", function () { return A.sort.bind([3, 1])().join("|"); });
t("bound.name", function () { return A.at.bind(null).name; });
t("bound bound.name", function () { return A.at.bind(null).bind(null).name; });

// --- 4. redefined `name` on a bound wrapper (fallback path reads it) -------
t("bound renamed to a probe name", function () {
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { value: "subarray", configurable: true });
  return f(1);
});
t("bound renamed utf16", function () {
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { value: "日本語", configurable: true });
  return f(1);
});
t("bound name deleted", function () {
  var f = A.at.bind([1, 2, 3]);
  delete f.name;
  return f(1);
});
t("bound name non-string", function () {
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { value: 42, configurable: true });
  return f(1);
});
t("bound name symbol", function () {
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { value: Symbol("s"), configurable: true });
  return f(1);
});
t("bound name throwing getter", function () {
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { get: function () { throw new RangeError("boom"); }, configurable: true });
  return f(1);
});
t("bound name counting getter", function () {
  var n = 0;
  var f = A.at.bind([1, 2, 3]);
  Object.defineProperty(f, "name", { get: function () { n++; return "at"; }, configurable: true });
  var v = f(1);
  return v + "/" + n;
});

// --- 5. redefining `name` on the intrinsic itself --------------------------
t("intrinsic name redefined", function () {
  var d = Object.getOwnPropertyDescriptor(A, "at");
  Object.defineProperty(A.at, "name", { value: "中文", configurable: true });
  var v = [1, 2, 3].at(1);
  Object.defineProperty(A.at, "name", { value: "at", configurable: true });
  Object.defineProperty(A, "at", d);
  return v;
});

// --- 6. accessor (`get X`) names reaching the probes ----------------------
var lenGet = Object.getOwnPropertyDescriptor(TA, "length").get;
t("get length name", function () { return lenGet.name; });
t("get length call", function () { return lenGet.call(new Uint8Array(4)); });
t("get length bound", function () { return lenGet.bind(new Uint8Array(4))(); });
var protoSet = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__").set;
t("set __proto__ name", function () { return protoSet.name; });
t("set __proto__ call", function () { var o = {}; protoSet.call(o, null); return Object.getPrototypeOf(o); });

// --- 7. symbol-derived names ---------------------------------------------
t("Symbol.iterator name", function () { return A[Symbol.iterator].name; });
t("Symbol.iterator call", function () { return A[Symbol.iterator].call([1, 2]).next().value; });
t("Symbol.hasInstance name", function () { return Function.prototype[Symbol.hasInstance].name; });
t("ta Symbol.toStringTag", function () { return Object.prototype.toString.call(new Uint8Array(1)); });

// --- 8. anonymous / renamed user callables in probe-adjacent positions -----
t("anon comparator", function () { return [3, 1, 2].sort(function (a, b) { return a - b; }).join("|"); });
t("anon map", function () { return [1, 2].map(function (x) { return x * 2; }).join("|"); });
t("named-utf16 callback", function () {
  var o = { "日": function (x) { return x + 1; } };
  return [1, 2].map(o["日"]).join("|");
});
t("arrow name", function () { var f = (x) => x; return f.name; });

// --- 9. proxies over natives ---------------------------------------------
t("proxy over slice", function () {
  var p = new Proxy(A.slice, {});
  return p.call([1, 2, 3], 1).join("|");
});
t("proxy over subarray", function () {
  var p = new Proxy(TA.subarray, {});
  return p.call(new Uint8Array([1, 2, 3]), 1).join("|");
});

// --- 10. species / constructor-name paths --------------------------------
t("species slice", function () {
  class MyArr extends Array {}
  var a = MyArr.from([1, 2, 3]);
  return (a.slice(1) instanceof MyArr) + "/" + a.slice(1).join("|");
});
t("ArrayBuffer.slice", function () { return new ArrayBuffer(8).slice(4).byteLength; });
t("ta species subarray", function () {
  class MyU8 extends Uint8Array {}
  var a = new MyU8([1, 2, 3]);
  return (a.subarray(1) instanceof MyU8) + "/" + a.subarray(1).join("|");
});
t("Array.from bound", function () { return Array.from.bind(Array)([1, 2]).join("|"); });
t("Array.of bound", function () { return Array.of.bind(Array)(1, 2).join("|"); });

// --- 11. cascade members reached with a wrong receiver -------------------
t("at on string receiver", function () { return A.at.call("abc", 1); });
t("subarray on array", function () { return TA.subarray.call([1, 2, 3], 1); });
t("slice on null", function () { return A.slice.call(null, 1); });
t("push on frozen", function () { var a = Object.freeze([1]); return A.push.call(a, 2); });
t("sort on detached", function () {
  var b = new ArrayBuffer(8);
  var v = new Uint8Array(b);
  return TA.sort.call(v);
});

// --- 12. names that collide with other cascade arms ----------------------
t("Symbol.for", function () { return Symbol.keyFor(Symbol.for("zz")); });
t("WeakRef.deref", function () { var o = {}; return typeof new WeakRef(o).deref(); });
t("BigInt.asIntN", function () { return String(BigInt.asIntN(8, 257n)); });
t("String.raw", function () { return String.raw`a${1}b`; });
t("indirect eval", function () { var e = eval; return e("1+1"); });
t("Uint8Array.toBase64", function () { return new Uint8Array([0, 1, 2]).toBase64(); });
t("Promise.then name", function () { return Promise.prototype.then.name; });
t("Map.groupBy", function () { return String(Map.groupBy([1, 2], function (x) { return x % 2; }).size); });
t("FinalizationRegistry.register", function () {
  var r = new FinalizationRegistry(function () {});
  var o = {};
  r.register(o, 1);
  return "registered";
});

// --- 13. array default-iterator detection (arrayUsesDefaultIterator) ------
t("spread default iterator", function () { return [...[1, 2, 3]].join("|"); });
t("spread patched iterator", function () {
  var a = [1, 2, 3];
  a[Symbol.iterator] = function () { return [9, 8][Symbol.iterator](); };
  return [...a].join("|");
});
t("spread bound values iterator", function () {
  var a = [1, 2, 3];
  a[Symbol.iterator] = A.values.bind(a);
  return [...a].join("|");
});
t("spread renamed values iterator", function () {
  var a = [1, 2, 3];
  var f = A.values.bind(a);
  Object.defineProperty(f, "name", { value: "values", configurable: true });
  a[Symbol.iterator] = f;
  return [...a].join("|");
});

// --- 14. isConstructorForArrayOf / builtin-constructor-name paths ---------
t("Array.of species ctor", function () {
  function C(n) { this.n = n; }
  return String(Array.of.call(C, 1, 2).n);
});
t("Array.from bound ctor", function () {
  function C(n) { this.length = n; }
  return String(Array.from.call(C, [1, 2]).length);
});
t("Reflect.construct Uint8Array", function () { return Reflect.construct(Uint8Array, [2]).length; });

print(out.join("\n"));
