(function () {
  const object = {
    get length() {
      return 1;
    },
  };

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object.length;
  }
  console.log(sum);
})();
