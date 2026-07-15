(function () {
  const limit = 2_000_000;
  const result = { value: 1, done: false };
  const iterator = {
    result,
    [Symbol.iterator]() {
      return this;
    },
    next() {
      return this.result;
    },
  };

  let count = 0;
  let sum = 0;
  for (const value of iterator) {
    sum = (sum + value) | 0;
    if (++count === limit) break;
  }
  console.log(sum, count);
})();
