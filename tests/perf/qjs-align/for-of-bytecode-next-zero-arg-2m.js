(function () {
  const limit = 2_000_000;
  let index = 0;
  const result = { value: 0, done: false };
  const iterator = {
    [Symbol.iterator]() {
      return this;
    },
    next() {
      if (index === limit) {
        result.done = true;
        return result;
      }
      result.value = index++;
      return result;
    },
  };

  let sum = 0;
  for (const value of iterator) sum = (sum + value) | 0;
  console.log(sum, index);
})();
