(function () {
  let objects = 0;
  for (let i = 0; i < 1_000_000; i++) {
    objects += Object(null) !== null;
  }
  console.log(objects);
})();
