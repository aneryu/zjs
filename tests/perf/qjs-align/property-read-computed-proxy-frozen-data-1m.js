(function () {
  const target = {};
  Object.defineProperty(target, "marker", {
    value: 1,
    writable: false,
    configurable: false,
  });
  const proxy = new Proxy(target, {
    get() {
      return 1;
    },
  });
  const key = "marker";

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += proxy[key];
  }
  console.log(sum);
})();
