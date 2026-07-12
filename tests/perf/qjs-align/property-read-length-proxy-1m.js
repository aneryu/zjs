(function () {
  const proxy = new Proxy(
    {},
    {
      get() {
        return 1;
      },
    },
  );

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += proxy.length;
  }
  console.log(sum);
})();
