(function () {
  function noop() {}

  let count = 0;
  for (; count < 10_000_000; count++) {
    noop();
  }
  console.log(count);
})();
