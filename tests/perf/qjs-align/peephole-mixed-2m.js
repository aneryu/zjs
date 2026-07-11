let sink = 0;

function hot(v) {
  let x = 0;
  let y = 0;
  y = (x = v);
  const z = x && y && 1;
  if (x && y && z) return y + z;
  if (x === null || typeof v === "undefined") return 1000;
  return 0;
}

function earlyReturn() {
  return;
  sink = -1;
}

for (let i = 0; i < 2_000_000; i++) sink += hot(i & 1);
earlyReturn();
console.log(sink);
