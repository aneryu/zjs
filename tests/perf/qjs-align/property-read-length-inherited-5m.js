(function () {
  const object = Object.create({ length: 1 });

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += object.length;
  }
  console.log(sum);
})();
