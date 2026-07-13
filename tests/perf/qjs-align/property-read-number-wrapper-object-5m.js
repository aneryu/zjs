(function () {
  const object = new Number(1);
  object.marker = 1;

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += object.marker;
  }
  console.log(sum);
})();
