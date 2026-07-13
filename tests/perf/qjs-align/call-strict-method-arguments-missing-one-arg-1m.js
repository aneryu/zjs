(function () {
  function one(value) {
    "use strict";
    return arguments.length + 1;
  }
  const receiver = { one };

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += receiver.one();
  }
  console.log(sum);
})();
