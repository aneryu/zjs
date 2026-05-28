// Realm prototype/constructor caches are internal slots, not global properties.
var names = [
  "__zjs_async_function_prototype",
  "__zjs_async_function_constructor",
  "__zjs_generator_prototype",
  "__zjs_generator_function_prototype",
  "__zjs_generator_function_constructor",
  "__zjs_async_iterator_prototype",
  "__zjs_async_generator_prototype",
  "__zjs_async_generator_function_prototype",
  "__zjs_async_generator_function_constructor",
  "__zjs_iterator_helper_prototype",
  "__zjs_iterator_concat_prototype",
  "__zjs_wrap_for_valid_iterator_prototype",
];

function dump(tag) {
  var line = tag;
  for (var i = 0; i < names.length; i++) {
    line += " " + (names[i] in globalThis);
  }
  print(line);
}

dump("before");
eval("(async function(){})");
eval("(function*(){})");
eval("(async function*(){})");
Iterator.from([1]).map(function(x) { return x; });
Iterator.concat([1], [2]);
Iterator.from({ next: function() { return { done: true }; } });
dump("after");

delete globalThis.Function;
var lazyMap = Array.prototype.map;
print("deleted Function lazy", typeof lazyMap, Object.getPrototypeOf(lazyMap) !== null);

delete globalThis.Promise;
async function deletedPromiseFactory() { return 1; }
var deletedPromise = deletedPromiseFactory();
print("deleted Promise async", Object.getPrototypeOf(deletedPromise) !== null);
