function run() {
  let sum = 0;
  for (let i = 0; i < 1000000; i++) {
    sum += (i * 8191) % 10000;
  }
  return sum;
}

console.log(run());
