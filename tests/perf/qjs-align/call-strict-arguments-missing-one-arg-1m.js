(function () {
  function one(value) {
    "use strict";
    return arguments.length + 1;
  }

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += one();
  }
  console.log(sum);
})();
