function run() {
  let value = "";
  for (let i = 0; i < 5000; i++) value += "ab";

  let sum = 0;
  for (let i = 0; i < 1000000; i++) {
    sum += value.charCodeAt((i * 8191) % value.length);
  }
  return sum;
}
console.log(run());
