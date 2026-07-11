function run() {
  var value = "";
  for (var i = 0; i < 500000; i++) value += "ab";
  return value.length;
}
console.log(run());
