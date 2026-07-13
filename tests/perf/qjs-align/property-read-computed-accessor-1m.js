(function () {
  const prototype = {};
  Object.defineProperty(prototype, "marker", {
    get() {
      return 1;
    },
  });
  const object = Object.create(prototype);
  const key = "marker";

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object[key];
  }
  console.log(sum);
})();
