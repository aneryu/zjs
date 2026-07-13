(function () {
  const values = [];
  let sum = 0;
  for (let i = 0; i < 5_000_000; i++) {
    sum += values.push(i);
    if (values.length === 1024) values.length = 0;
  }
  console.log(sum);
})();
