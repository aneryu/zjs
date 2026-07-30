function run() {
  const a = [1,2,3,4,5,6,7,8,9,10];
  const f = (x) => x + 1;
  let out = null;
  for (let i = 0; i < 1000000; i++) { out = a.map(f); }
  const t = out[9];
  return t;
}
print(run());
