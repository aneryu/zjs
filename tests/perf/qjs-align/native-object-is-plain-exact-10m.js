(function () {
  const same = Object.is;
  const value = undefined;
  let result = false;
  for (let i = 0; i < 10_000_000; i++) {
    result = same(value, value);
  }
  console.log(result === true);
})();
