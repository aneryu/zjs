function run() {
  const a = [1,2,3,4,5,6,7,8,9,10];
  let t = 0;
  for (let i = 0; i < 100000; i++) {
    for (let j = 0; j < 10; j++) { t = a[j]; }
  }
  return t;
}
print(run());
