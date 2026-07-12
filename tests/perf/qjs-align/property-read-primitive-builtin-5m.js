(function () {
  const expected = Number.prototype.toString;

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += (1).toString === expected;
  }
  console.log(sum);
})();
