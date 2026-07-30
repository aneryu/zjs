function run() {
  const a = [1];
  const f = (x) => x + 1;
  let t = 0;
  for (let i = 0; i < 100000; i++) { a.forEach(f); t = i; }
  return t;
}
print(run());
