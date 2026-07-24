globalThis.dynamicPutProperty = 0;

(function () {
  for (var i = 0; i < 5_000_000; i++) {
    dynamicPutProperty = i;
  }
  print(dynamicPutProperty);
})();
