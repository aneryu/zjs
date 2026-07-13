(function () {
  Number.prototype.marker = 1;
  const key = "marker";

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += (1)[key];
  }
  delete Number.prototype.marker;
  console.log(sum);
})();
