(function () {
  const abs = Math.abs;
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result = abs();
  }
  console.log(result !== result);
})();
