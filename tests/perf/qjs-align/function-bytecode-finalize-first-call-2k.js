let sum = 0;

for (let i = 0; i < 2_000; i++) {
  const fn = eval("(function fb_first_call_" + i + "(value) { return value + 1; })");
  sum += fn(1);
}

console.log(sum);
