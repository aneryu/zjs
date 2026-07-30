function run() {
  let g = null;
  for (let i = 0; i < 100000; i++) { g = (x) => x + 1; }
  const t = g(1);
  return t;
}
print(run());
