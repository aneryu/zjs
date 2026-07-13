(function () {
  const object = new Uint8Array(1);

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object.byteLength;
  }
  console.log(sum);
})();
