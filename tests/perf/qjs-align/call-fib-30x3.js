(function () {
  function fib(n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
  }

  let sum = 0;
  for (let i = 0; i < 3; i++) {
    sum += fib(30);
  }
  console.log(sum);
})();
