(function () {
  var captured = 0;

  function run() {
    let sum = 0;
    for (let i = 0; i < 20_000_000; i++) {
      sum = (sum + (captured = i)) | 0;
    }
    return sum;
  }

  print(run(), captured);
})();
