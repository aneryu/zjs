(function () {
  Number.prototype.readThis = function readThis() {
    "use strict";
    return this;
  };

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += (1).readThis() === 1;
  }
  delete Number.prototype.readThis;
  console.log(sum);
})();
