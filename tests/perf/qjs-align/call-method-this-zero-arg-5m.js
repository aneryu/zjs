(function () {
  const receiver = {
    value: 1,
    readThis() {
      return this;
    },
  };

  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += receiver.readThis() === receiver;
  }
  console.log(sum);
})();
