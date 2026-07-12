function run() {
  let base = "";
  for (let i = 0; i < 5000; i++) base += "ab";

  let sum = 0;
  for (let i = 0; i < 20000; i++) {
    const derived = base + "xy";
    sum += derived.charCodeAt(9000);
  }
  return sum;
}
console.log(run());
