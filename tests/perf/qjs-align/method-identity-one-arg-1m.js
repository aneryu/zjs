(function () {
  const promise = Promise.resolve(1);
  const holder = {
    identity(value) {
      return value;
    },
  };
  let matches = 0;
  for (let i = 0; i < 1_000_000; i++) {
    matches += holder.identity(promise) === promise;
  }
  console.log(matches);
})();
