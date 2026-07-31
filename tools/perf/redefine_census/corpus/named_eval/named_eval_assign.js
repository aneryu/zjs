// NamedEvaluation position: IdentifierReference assignment target. The engine
// must re-define the `name` property that already exists on the fresh function.
let g;
let n = 0;
for (let i = 0; i < 20000; i++) { g = (x) => x + 1; n += g(i) & 1; }
print(n);
