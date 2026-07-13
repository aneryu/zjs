(function () {
  const promise = Promise.resolve(1);
  const resolve = Promise.resolve;
  let matches = 0;
  for (let i = 0; i < 1_000_000; i++) {
    matches += resolve.call(Promise, promise) === promise;
  }
  console.log(matches);
})();
