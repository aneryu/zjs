(function () {
  var localValue = 0;
  for (var i = 0; i < 20_000_000; i++) {
    localValue = i;
  }
  print(localValue);
})();
