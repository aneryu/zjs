function run() {
  const a = [];
  const f = (x) => x + 1;
  let out = null;
  for (let i = 0; i < 100000; i++) { out = a.map(f); }
  const t = out.length;
  return t;
}
print(run());
