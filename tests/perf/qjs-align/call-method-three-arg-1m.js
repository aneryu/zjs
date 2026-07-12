(function () {
  function one(target, key, receiver) {
    void target;
    void key;
    void receiver;
    return 1;
  }
  const handler = { one };
  const target = {};
  const key = "marker";
  const receiver = {};

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += handler.one(target, key, receiver);
  }
  console.log(sum);
})();
