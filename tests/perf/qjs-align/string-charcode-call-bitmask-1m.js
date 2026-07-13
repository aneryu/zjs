function run() {
  let value = "";
  for (let i = 0; i < 4096; i++) value += "ab";

  let sum = 0;
  for (let i = 0; i < 1000000; i++) {
    sum += value.charCodeAt(i & 8191);
  }
  return sum;
}

console.log(run());
