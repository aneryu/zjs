function run() {
  const src = [null, null, null, null];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    u = !x;
  }
  return (u ? 1 : 0) + t;
}
print(run());
