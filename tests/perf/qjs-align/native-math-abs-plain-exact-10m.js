(function () {
  const abs = Math.abs;
  const value = 0 / 0;
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result = abs(value);
  }
  console.log(result !== result);
})();
