function run() {
  const a = [];
  function cb_ident(v, i, arr) { return v; }
  function cb_noop(v, i, arr) { }
  function cb_false(v, i, arr) { return false; }
  function cb_true(v, i, arr) { return true; }
  function cb_acc(acc, v, i, arr) { return acc; }
  const LEN = 0;
  let t = 0;
  for (let n = 0; n < 100000; n++) { a.forEach(cb_noop); t = n; }
  return t;
}
print(run());
print(run());
