(function () {
  const object = {};

  let value;
  for (let i = 0; i < 5_000_000; i++) {
    value = object.missing;
  }
  console.log(value === undefined);
})();
