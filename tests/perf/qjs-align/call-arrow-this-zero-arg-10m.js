(function () {
  const owner = {
    value: 1,
    makeReader() {
      return () => this.value;
    },
  };
  const read = owner.makeReader();

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += read();
  }
  console.log(sum);
})();
