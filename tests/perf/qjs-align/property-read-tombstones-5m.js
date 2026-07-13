function run() {
  const object = {};
  for (let i = 0; i < 64; i++) object["dead" + i] = i;
  object.hot = 7;
  for (let i = 0; i < 64; i++) delete object["dead" + i];
  let sum = 0;
  for (let i = 0; i < 5000000; i++) sum += object.hot;
  return sum;
}
console.log(run());
