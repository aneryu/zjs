function run() {
  const a = [1];
  const f = (x) => x + 1;
  let out = null;
  for (let i = 0; i < 100000; i++) { out = a.map(f); }
  const t = out[0];
  return t;
}
print(run());
