(function () {
  const proxy = new Proxy({ marker: 1 }, {});

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += proxy.marker;
  }
  console.log(sum);
})();
