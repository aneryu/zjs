(function () {
  const holder = { same: Object.is };
  const value = undefined;
  let result = false;
  for (let i = 0; i < 10_000_000; i++) {
    result = holder.same(value, value);
  }
  console.log(result === true);
})();
