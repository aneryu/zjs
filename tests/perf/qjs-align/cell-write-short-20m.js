(function () {
  var captured = 0;

  function run() {
    for (let i = 0; i < 20_000_000; i++) {
      captured = i;
    }
  }

  run();
  print(captured);
})();
