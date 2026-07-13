(function () {
  const promise = Promise.resolve(1);
  let matches = 0;
  for (let i = 0; i < 1_000_000; i++) {
    matches += promise.constructor === Promise;
  }
  console.log(matches);
})();
