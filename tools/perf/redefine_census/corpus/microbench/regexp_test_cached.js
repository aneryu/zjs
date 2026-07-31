const r = /a+b/;
let c = 0;
for (let i = 0; i < 100000; i++) if (r.test("aaab")) c++;
print(c);
