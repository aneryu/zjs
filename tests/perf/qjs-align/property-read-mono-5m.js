function run() {
  const object = { a: 1, b: 2, c: 3, hot: 7 };
  let sum = 0;
  for (let i = 0; i < 5000000; i++) sum += object.hot;
  return sum;
}
console.log(run());
