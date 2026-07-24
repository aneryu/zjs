var dynamicPutChecksum = 0;

(function () {
  for (var i = 0; i < 5_000_000; i++) {
    dynamicPutChecksum = ((dynamicPutChecksum * 33) ^ i) | 0;
  }
  print(dynamicPutChecksum);
})();
