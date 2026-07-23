(function () {
  const same = Object.is;
  let result = false;
  for (let i = 0; i < 10_000_000; i++) {
    result = same();
  }
  console.log(result === true);
})();
