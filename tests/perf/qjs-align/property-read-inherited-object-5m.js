(function () {
  const prototype = { marker: 1 };
  const object = Object.create(prototype);

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += object.marker;
  }
  console.log(sum);
})();
