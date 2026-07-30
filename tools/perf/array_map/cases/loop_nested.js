function run() {
  let t = 0;
  for (let i = 0; i < 100000; i++) {
    for (let j = 0; j < 10; j++) { t = j; }
  }
  return t;
}
print(run());
