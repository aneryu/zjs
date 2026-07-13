(function () {
  const object = new Uint8Array(1);
  Object.defineProperty(object, "length", {
    get() {
      return 2;
    },
  });

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object.length;
  }
  console.log(sum);
})();
