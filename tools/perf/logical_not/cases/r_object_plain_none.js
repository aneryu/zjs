function run() {
  const src = [{a: 1}, {a: 2}, {a: 3}, {a: 4}];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    t = t + 1;
  }
  return (u ? 1 : 0) + t;
}
print(run());
