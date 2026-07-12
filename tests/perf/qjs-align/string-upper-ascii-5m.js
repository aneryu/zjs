(function () {
  const value = "abcdefghijklmnopqrstuvwxyz";
  let total = 0;
  for (let i = 0; i < 5_000_000; i++) {
    total += value.toUpperCase().length;
  }
  console.log(total);
})();
