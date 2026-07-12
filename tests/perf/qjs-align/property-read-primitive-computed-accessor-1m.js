(function () {
  const key = "marker";
  Object.defineProperty(Number.prototype, key, {
    configurable: true,
    get() {
      return 1;
    },
  });

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += (1)[key];
  }
  delete Number.prototype[key];
  console.log(sum);
})();
