let created = 0;

for (let i = 0; i < 2_000; i++) {
  const fn = eval("(function fb_no_call_" + i + "(value) { return value + 1; })");
  if (typeof fn === "function") created++;
}

console.log(created);
