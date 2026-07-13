(function () {
  const object = new Uint8Array(new ArrayBuffer(2), 1, 1);

  let sum = 0;
  for (let i = 0; i < 1_000_000; i++) {
    sum += object.byteOffset;
  }
  console.log(sum);
})();
