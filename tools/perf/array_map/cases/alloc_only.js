function run() {
  let out = null;
  for (let i = 0; i < 100000; i++) { out = new Array(10); }
  const t = out.length;
  return t;
}
print(run());
