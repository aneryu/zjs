(function () {
  const proxy = new Proxy(
    { marker: 1 },
    {
      get(target, key, receiver) {
        return Reflect.get(target, key, receiver);
      },
    },
  );
  const object = Object.create(proxy);
  const key = "marker";

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object[key];
  }
  console.log(sum);
})();
