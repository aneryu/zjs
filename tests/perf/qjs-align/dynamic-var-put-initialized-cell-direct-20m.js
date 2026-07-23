var dynamicPutCell = 0;

(function () {
  for (var i = 0; i < 20_000_000; i++) {
    dynamicPutCell = i;
  }
  print(dynamicPutCell);
})();
