(function () {
  const proxy = new Proxy({ marker: 1 }, {});
  const key = "marker";

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += proxy[key];
  }
  console.log(sum);
})();
