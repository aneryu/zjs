var symbols = [
  typeof Symbol.dispose,
  typeof Symbol.asyncDispose,
  Symbol.keyFor(Symbol.dispose),
  Symbol.keyFor(Symbol.asyncDispose),
];
print(symbols.join("|"));

var log = [];
{
  using first = {
    name: "first",
    [Symbol.dispose]: function() {
      log.push("dispose:" + this.name);
    },
  };
  using second = {
    name: "second",
    [Symbol.dispose]: function() {
      log.push("dispose:" + this.name);
    },
  };
  log.push("body");
}
print(log.join("|"));

var stack = new DisposableStack();
print(stack.disposed);
stack.defer(function() {
  log.push("stack:defer");
});
stack.adopt("value", function(value) {
  log.push("stack:adopt:" + value + ":" + (this === undefined));
});
var resource = {
  name: "resource",
  [Symbol.dispose]: function() {
    log.push("stack:use:" + this.name);
  },
};
print(stack.use(resource) === resource);
stack.dispose();
print(stack.disposed);
print(log.slice(3).join("|"));

var asyncLog = [];
var asyncStack = new AsyncDisposableStack();
asyncStack.defer(function() {
  asyncLog.push("async:defer");
  return Promise.resolve().then(function() {
    asyncLog.push("async:defer:then");
  });
});
asyncStack.use({
  [Symbol.asyncDispose]: function() {
    asyncLog.push("async:use");
    return Promise.resolve().then(function() {
      asyncLog.push("async:use:then");
    });
  },
});
asyncStack.disposeAsync().then(function() {
  print(asyncStack.disposed);
  print(asyncLog.join("|"));
}, function(error) {
  print("async-error:" + error.name);
});
