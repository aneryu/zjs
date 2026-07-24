(function () {
  const holder = { abs: Math.abs };
  let result = 0;
  for (let i = 0; i < 10_000_000; i++) {
    result = holder.abs();
  }
  console.log(result !== result);
})();
