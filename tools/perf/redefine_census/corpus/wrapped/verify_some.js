function run() {
  const a = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,100];
  function cb_ident(v, i, arr) { return v; }
  function cb_noop(v, i, arr) { }
  function cb_false(v, i, arr) { return false; }
  function cb_true(v, i, arr) { return true; }
  function cb_acc(acc, v, i, arr) { return acc; }
  const LEN = 100;
  let calls = 0, bad_argc = 0, bad_arr = 0, bad_idx = 0, bad_val = 0, this_global = 0;
  const sink = new Array(LEN);
  function cbv(v, i, arr) {
    if (arguments.length !== 3) { bad_argc++; }
    if (arr !== a) { bad_arr++; }
    if (i !== calls) { bad_idx++; }
    if (v !== a[i]) { bad_val++; }
    if (this === globalThis) { this_global++; }
    calls++;
    return false;
  }
  a.some(cbv);
  const bi = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  calls = 0; bad_argc = 0; bad_arr = 0; bad_idx = 0; bad_val = 0; this_global = 0;
  for (let j = 0; j < LEN; j++) { if (cbv(a[j], j, a)) { break; } }
  const co = [calls, bad_argc, bad_arr, bad_idx, bad_val, this_global].join("/");
  const t = "some builtin=" + bi + " control=" + co;
  return t;
}
print(run());
print(run());
