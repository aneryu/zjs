(function () {
  const holder = { abs: Math.abs };
  const value = 0 / 0;
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result = holder.abs(value);
  }
  console.log(result !== result);
})();
