// Iterator helper runtime state is internal metadata.
var helper = Iterator.from([1, 2]).map(function(x) {
  return x + 1;
});
print("__zjs_iterator_helper_next" in helper);
print("__zjs_iterator_callback" in helper);
helper.__zjs_iterator_helper_next = function() {
  return { done: false, value: 40 };
};
helper.__zjs_iterator_callback = function(x) {
  return x + 1000;
};
var mapped = helper.next();
print(mapped.done, mapped.value);

var flatMapped = Iterator.from([1]).flatMap(function(x) {
  return [x, x + 1];
});
print("__zjs_iterator_helper_inner_next" in flatMapped);
print(flatMapped.next().value);
flatMapped.__zjs_iterator_helper_inner_next = function() {
  return { done: false, value: 999 };
};
print(flatMapped.next().value);

var zipped = Iterator.zip([[1], [2]]);
print("__zjs_iterator_zip_state" in zipped);
print("__zjs_iterator_zip_nexts" in zipped);
zipped.__zjs_iterator_zip_state = 3;
zipped.__zjs_iterator_zip_nexts = {};
zipped.__zjs_iterator_zip_pads = {};
var zippedResult = zipped.next();
print(zippedResult.done, JSON.stringify(zippedResult.value));

var keyed = Iterator.zipKeyed({ a: [3], b: [4] });
print("__zjs_iterator_zip_keys" in keyed);
keyed.__zjs_iterator_zip_keys = { 0: "x", 1: "y" };
var keyedResult = keyed.next();
print(
  keyedResult.done,
  keyedResult.value.a,
  keyedResult.value.b,
  Object.prototype.hasOwnProperty.call(keyedResult.value, "x")
);
