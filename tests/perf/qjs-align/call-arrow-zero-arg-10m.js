(function () {
  const one = () => 1;

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += one();
  }
  console.log(sum);
})();
