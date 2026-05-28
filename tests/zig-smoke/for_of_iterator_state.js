// for-of must not expose internal iterator next/cache state.
var it = {
  i: 0,
  [Symbol.iterator]: function() { return this; },
  next: function() {
    this.i++;
    return { done: this.i > 1, value: this.i };
  },
};

for (var value of it) print("sync", value);
print(Object.getOwnPropertyNames(it).join(","));
print("__zjs_iterator_next" in it);
print(Object.getOwnPropertyDescriptor(it, "__zjs_iterator_next") === undefined);
it.i = 0;
it.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
for (var collisionValue of it) {
  print("collision", collisionValue);
  break;
}
print(delete it.__zjs_iterator_next);

var sealed = Object.preventExtensions({
  i: 0,
  [Symbol.iterator]: function() { return this; },
  next: function() {
    this.i++;
    return { done: this.i > 1, value: this.i };
  },
});

try {
  for (var sealedValue of sealed) print("sealed", sealedValue);
  print("ok", sealed.i);
} catch (e) {
  print(e.name);
}

var arrayIteratorNext = Object.getPrototypeOf([][Symbol.iterator]()).next;
var fakeArrayIterator = {
  __zjs_array_iter_target: [7, 8],
  __zjs_array_iter_index: 0,
};
try {
  var fakeArrayIteratorResult = arrayIteratorNext.call(fakeArrayIterator);
  print("array iterator fake", fakeArrayIteratorResult.done, fakeArrayIteratorResult.value);
} catch (e) {
  print("array iterator fake", e.name);
}
print(fakeArrayIterator.__zjs_array_iter_index);
var realArrayIterator = [7, 8][Symbol.iterator]();
print("array iterator real", realArrayIterator.next().value, realArrayIterator.next().value);

async function checkAsyncIterator() {
  var asyncIterator = Object.preventExtensions({
    i: 0,
    [Symbol.asyncIterator]: function() { return this; },
    next: function() {
      this.i++;
      return Promise.resolve({ done: this.i > 1, value: this.i });
    },
  });

  for await (var asyncValue of asyncIterator) print("async", asyncValue);
  print("async ok", asyncIterator.i);
  print(Object.getOwnPropertyNames(asyncIterator).join(","));
  print("__zjs_iterator_next" in asyncIterator);
  print("__zjs_async_iterator" in asyncIterator);
}

checkAsyncIterator();
