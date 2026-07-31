function run() {
  const src = [123456789012345678901234567890n, 1n, 2n, 3n];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    u = x;
  }
  return (u ? 1 : 0) + t;
}
print(run());
