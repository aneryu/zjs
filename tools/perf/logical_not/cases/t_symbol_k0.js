function run() {
  const src = [Symbol("s1"), Symbol("s2"), Symbol("s3"), Symbol("s4")];
  let x = src[0];
  let u = 0;
  let t = 0;
  for (let i = 0; i < 20000000; i++) {
    u = x;
  }
  return (u ? 1 : 0) + t;
}
print(run());
