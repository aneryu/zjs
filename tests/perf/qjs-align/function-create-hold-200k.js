const functions = new Array(200_000);
for (let i = 0; i < 200_000; i++) {
  functions[i] = function () {
    return 1;
  };
}
console.log(functions.length);
