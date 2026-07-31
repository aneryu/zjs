function run() {
  const a = [1,2,3,4,5,6,7,8,9,10];
  const f = (x) => x + 1;
  const out = new Array(10);
  for (let i = 0; i < 100000; i++) {
    for (let j = 0; j < 10; j++) { out[j] = f(a[j]); }
  }
  const t = out[9];
  return t;
}
print(run());
