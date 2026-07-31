function run() {
  const a = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100];
  function cb_noop(v, i, arr) { }
  function cb_false(v, i, arr) { return false; }
  function cb_true(v, i, arr) { return true; }
  function cb_a0() { }
  function cb_a1(v) { }
  function cb_a2(v, i) { }
  function cb_a3(v, i, arr) { }
  function cb_a0f() { return false; }
  const LEN = 100;
  let t = 0;
  for (let n = 0; n < 100; n++) {
    const out = [];
    let m = 0;
    for (let j = 0; j < LEN; j++) {
      const v = a[j];
      if (cb_false(v, j, a)) { out[m] = v; m++; }
    }
    t = out.length;
  }
  return t;
}
print(run());
