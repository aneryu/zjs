let sum = 0;
for (let i = 0; i < 5; i++) sum += i;
print(sum);

let i = 0;
while (i < 3) { i++; }
print(i);

function classify(n) {
  if (n < 0) return 'neg';
  if (n === 0) return 'zero';
  return 'pos';
}
print(classify(-1), classify(0), classify(1));

let out = '';
switch (2) {
  case 1: out = 'one'; break;
  case 2: out = 'two'; break;
  default: out = 'other';
}
print(out);
