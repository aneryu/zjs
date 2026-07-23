var marker = 1;

(function () {
  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += globalThis.marker;
  }
  console.log(sum);
})();
