// Auto-init builtin markers are internal and stable across user properties.
function check(fn, marker, run) {
  print(marker in fn);
  print(Object.getOwnPropertyDescriptor(fn, marker) === undefined);
  fn[marker] = 0;
  print(run());
  print(delete fn[marker]);
  print(run());
}

check(Object.assign, "__zjs_object_static", function() {
  var target = {};
  Object.assign(target, { x: 1 });
  return target.x;
});
check(Object.defineProperty, "__zjs_define_property_kind", function() {
  var object = {};
  Object.defineProperty(object, "x", { value: 1 });
  return object.x;
});
check(Object.prototype.hasOwnProperty, "__zjs_object_method", function() {
  return Object.prototype.hasOwnProperty.call({ x: 1 }, "x");
});
check(String.prototype.includes, "__zjs_string_method", function() {
  return "abc".includes("b");
});
check(Number.prototype.toFixed, "__zjs_number_method", function() {
  return (7).toFixed(0);
});
check(String.prototype.valueOf, "__zjs_primitive_method", function() {
  return String.prototype.valueOf.call("zjs");
});
check(Date.prototype[Symbol.toPrimitive], "__zjs_date_to_primitive", function() {
  return Date.prototype[Symbol.toPrimitive].call(new Date(0), "number");
});
check(RegExp.prototype.test, "__zjs_regexp_method", function() {
  return /a/.test("a");
});
check(JSON.parse, "__zjs_json_static", function() {
  return JSON.parse("{\"x\":1}").x;
});
check(JSON.stringify, "__zjs_json_static", function() {
  return JSON.stringify({ x: 1 });
});
check(Reflect.apply, "__zjs_reflect_static", function() {
  return Reflect.apply(function(x) { return x + 1; }, null, [2]);
});
check(Reflect.setPrototypeOf, "__zjs_reflect_set_prototype_of", function() {
  var proto = { x: 1 };
  var object = {};
  return Reflect.setPrototypeOf(object, proto) && object.x;
});
check(Reflect.defineProperty, "__zjs_define_property_kind", function() {
  var object = {};
  return Reflect.defineProperty(object, "x", { value: 1 }) && object.x;
});
check(Atomics.isLockFree, "__zjs_atomics_static", function() {
  return Atomics.isLockFree(4);
});
check(Map.prototype.get, "__zjs_collection_method_owner", function() {
  return Map.prototype.get.call(new Map([["x", 2]]), "x");
});
check(Object.getOwnPropertyDescriptor(Map.prototype, "size").get, "__zjs_collection_method_owner", function() {
  return Object.getOwnPropertyDescriptor(Map.prototype, "size").get.call(new Map([["x", 2]]));
});
check(Array.prototype.concat, "__zjs_array_concat", function() {
  return [1].concat([2]).join(",");
});
check(Array.prototype.keys, "__zjs_array_iterator_kind", function() {
  return Array.prototype.keys.call([7]).next().value;
});
check(Array.prototype.values, "__zjs_array_iterator_kind", function() {
  return Array.prototype.values.call([7]).next().value;
});
check(Array.prototype.entries, "__zjs_array_iterator_kind", function() {
  return Array.prototype.entries.call([7]).next().value.join(",");
});
check(ArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
  return new ArrayBuffer(4).slice(1).byteLength;
});
check(SharedArrayBuffer.prototype.slice, "__zjs_buffer_method_kind", function() {
  return new SharedArrayBuffer(4).slice(1).byteLength;
});
check(Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
  return new ArrayBuffer(4).byteLength;
});
check(Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, "byteLength").get, "__zjs_buffer_accessor_kind", function() {
  return new SharedArrayBuffer(4).byteLength;
});
check(Object.getOwnPropertyDescriptor(DataView.prototype, "byteLength").get, "__zjs_dataview_accessor", function() {
  return new DataView(new ArrayBuffer(6), 1, 3).byteLength;
});
check(Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "length").get, "__zjs_typedarray_accessor", function() {
  return new Uint8Array(5).length;
});
check(Uint8Array.from, "__zjs_typedarray_static", function() {
  return Uint8Array.from([1, 2])[1];
});
check(Uint8Array.of, "__zjs_typedarray_static", function() {
  return Uint8Array.of(3, 4)[1];
});
check(Uint8Array.prototype.slice, "__zjs_typedarray_method", function() {
  return new Uint8Array([1, 2]).slice(1)[0];
});
