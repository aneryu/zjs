(function () {
  function one(value) {
    return 1;
  }
  const receiver = { one };

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += receiver.one();
  }
  console.log(sum);
})();
