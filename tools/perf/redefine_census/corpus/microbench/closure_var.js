function counter() { let n = 0; return function () { n++; return n; }; }
let next = counter();
print(next());
print(next());
