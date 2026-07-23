(function () {
  function echo(x) {
    return x;
  }
  const receiver = { echo };

  let sum = 0;
  for (let i = 0; i < 10_000_000; i++) {
    sum += receiver.echo(i);
  }
  console.log(sum);
})();
