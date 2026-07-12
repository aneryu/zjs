(function () {
  Number.prototype.one = function one() {
    return 1;
  };

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += (0, (1).one)();
  }
  delete Number.prototype.one;
  console.log(sum);
})();
