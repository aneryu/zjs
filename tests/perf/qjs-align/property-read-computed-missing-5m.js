(function () {
  const object = {};
  const key = "missing";

  let value;
  for (let i = 0; i < 5_000_000; i++) {
    value = object[key];
  }
  console.log(value === undefined);
})();
