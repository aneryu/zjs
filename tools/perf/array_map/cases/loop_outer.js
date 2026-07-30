function run() {
  let t = 0;
  for (let i = 0; i < 100000; i++) { t = i; }
  return t;
}
print(run());
