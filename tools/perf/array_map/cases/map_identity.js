function run() {
  const a = [1,2,3,4,5,6,7,8,9,10];
  const id = (x) => x;
  let out = null;
  for (let i = 0; i < 100000; i++) { out = a.map(id); }
  const t = out[9];
  return t;
}
print(run());
