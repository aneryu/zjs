(function () {
  function one() {
    return 1;
  }

  const expected = Function.prototype.call;
  let matches = 0;
  for (let i = 0; i < 20_000_000; i++) {
    if (one.call === expected) matches++;
  }
  console.log(matches);
})();
