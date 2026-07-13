(function () {
  const object = Object;
  const value = {};
  let matches = 0;
  for (let i = 0; i < 1_000_000; i++) {
    matches += new object(value) === value;
  }
  console.log(matches);
})();
