(function () {
  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += 1;
  }
  console.log(sum);
})();
