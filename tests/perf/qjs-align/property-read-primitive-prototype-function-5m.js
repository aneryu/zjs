(function () {
  const marker = function marker() {};
  Number.prototype.marker = marker;

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += (1).marker === marker;
  }
  delete Number.prototype.marker;
  console.log(sum);
})();
