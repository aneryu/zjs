(function () {
  const limit = 5_000_000;
  const arr = new Array(1024).fill(0);
  let i = 0;
  while (i < limit) {
    arr[i++ & 1023] = i;
  }
  console.log(arr[0], arr[1023], i);
})();
