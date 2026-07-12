(function () {
  const prototype = Number.prototype;
  prototype.marker = 1;

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += prototype.marker;
  }
  delete prototype.marker;
  console.log(sum);
})();
