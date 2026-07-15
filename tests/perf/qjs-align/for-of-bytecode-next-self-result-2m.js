(function () {
  const limit = 2_000_000;
  const iterator = {
    value: 1,
    done: false,
    [Symbol.iterator]() {
      return this;
    },
    next() {
      return this;
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
