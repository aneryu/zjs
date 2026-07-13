(function () {
  let checksum = 0;
  for (let i = 0; i < 2000000; i++) {
    const value = "ab" + i;
    checksum += value.length;
  }
  console.log(checksum);
})();
