(function () {
  function one(value) {
    "use strict";
    if (value === null) return arguments.length;
    return 1;
  }
  const receiver = { one };

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += receiver.one(0);
  }
  console.log(sum);
})();
