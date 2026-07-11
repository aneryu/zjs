function run() {
  const object = { a: 1, b: 2, c: 3, hot: 7 };
  const key = "hot";
  let sum = 0;
  for (let i = 0; i < 5000000; i++) sum += object[key];
  return sum;
}
console.log(run());
