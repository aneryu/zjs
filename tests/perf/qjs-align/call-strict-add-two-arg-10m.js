(function () {
  function add(a, b) {
    "use strict";
    return a + b;
  }

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum = add(sum, 1);
  }
  console.log(sum);
})();
