(function () {
  function one(value) {
    "use strict";
    return 1;
  }

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += one();
  }
  console.log(sum);
})();
