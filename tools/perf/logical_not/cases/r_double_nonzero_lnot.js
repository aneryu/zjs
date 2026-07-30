function run() {
  const src = [1.5, 1.5, 1.5, 1.5];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    if (!x) { } else { t = t + 1; }
  }
  return (u ? 1 : 0) + t;
}
print(run());
