// Iterator.from mirrors the local QuickJS wrapper selection.
var count = 0;
var iterable = {
  [Symbol.iterator]: function() { return this; },
  get next() {
    count++;
    return function() { return { done: true, value: 1 }; };
  },
};

var fromIterable = Iterator.from(iterable);
print(fromIterable === iterable);
print(count);
fromIterable.next();
print(count);
print(typeof fromIterable.map);

var sealed = Object.preventExtensions({
  next: function() { return { done: true }; },
});
var wrapped = Iterator.from(sealed);
print(wrapped === sealed);
print(wrapped.next().done);
print("__zjs_iterator_next" in wrapped);
print(Object.getOwnPropertyDescriptor(wrapped, "__zjs_iterator_next") === undefined);
wrapped.__zjs_iterator_next = function() { return { done: false, value: 99 }; };
print(wrapped.next().value);
print(delete wrapped.__zjs_iterator_next);
print("__zjs_iterator_next" in wrapped);

var bad = Iterator.from({ next: 1 });
print(typeof bad);
try {
  bad.next();
} catch (e) {
  print(e.name);
}
