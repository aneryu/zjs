(function () {
  var capturedValue = 0;
  function writeCaptured() {
    for (var i = 0; i < 20_000_000; i++) {
      capturedValue = i;
    }
  }
  writeCaptured();
  print(capturedValue);
})();
