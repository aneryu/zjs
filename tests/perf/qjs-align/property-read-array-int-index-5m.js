(function () {
  const array = [1];
  const key = 0;

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += array[key];
  }
  console.log(sum);
})();
