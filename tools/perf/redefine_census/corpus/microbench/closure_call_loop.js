function make(x) { return function(y) { return x + y; }; }
const f = make(1);
let s = 0;
for (let i = 0; i < 500000; i++) s += f(i);
print(s);
