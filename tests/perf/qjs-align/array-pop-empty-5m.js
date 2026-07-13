(function () {
  const array = [];
  let empty = 0;
  for (let i = 0; i < 5_000_000; i++) {
    empty += array.pop() === undefined;
  }
  console.log(empty);
})();
