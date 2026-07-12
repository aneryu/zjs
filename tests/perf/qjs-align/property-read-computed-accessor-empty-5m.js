(function () {
  const prototype = {};
  Object.defineProperty(prototype, "marker", { get: undefined });
  const object = Object.create(prototype);
  const key = "marker";

  let value;
  for (let i = 0; i < 5_000_000; i++) {
    value = object[key];
  }
  console.log(value === undefined);
})();
