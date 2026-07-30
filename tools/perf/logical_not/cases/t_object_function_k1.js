function run() {
  const src = [function f1() {}, function f2() {}, function f3() {}, function f4() {}];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    u = !x;
  }
  return (u ? 1 : 0) + t;
}
print(run());
