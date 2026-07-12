(function () {
  function makeAdder() {
    return function add(a, b) {
      return a + b;
    };
  }

  const add = makeAdder();
  let sum = 0;
  for (let i = 1; i <= 10_000_000; i++) {
    sum = add(sum, i);
  }
  console.log(sum);
})();
