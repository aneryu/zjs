(function () {
  Object.defineProperty(Number.prototype, "marker", {
    configurable: true,
    get() {
      return 1;
    },
  });

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += (1).marker;
  }
  delete Number.prototype.marker;
  console.log(sum);
})();
