(function () {
  const abs = Math.abs;
  const holder = { abs };
  let result;
  for (let i = 0; i < 10_000_000; i++) {
    result = holder.abs;
  }
  console.log(result === abs);
})();
