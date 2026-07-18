(function () {
  const limit = 5_000_000;
  let i = 0;
  let last = 0;
  while (i < limit) {
    last = i++;
  }
  console.log(last, i);
})();
