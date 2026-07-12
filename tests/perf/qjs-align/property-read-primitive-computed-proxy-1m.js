(function () {
  const key = "marker";
  const originalParent = Object.getPrototypeOf(Number.prototype);
  const proxy = new Proxy(originalParent, {
    get(target, property, receiver) {
      if (property === key) return 1;
      return Reflect.get(target, property, receiver);
    },
  });
  Object.setPrototypeOf(Number.prototype, proxy);

  let sum = 0;
  try {
    for (let i = 0; i < 1_000_000; i++) {
      sum += (1)[key];
    }
  } finally {
    Object.setPrototypeOf(Number.prototype, originalParent);
  }
  console.log(sum);
})();
