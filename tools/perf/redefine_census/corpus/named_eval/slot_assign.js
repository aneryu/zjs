// Same closure creation, non-NamedEvaluation target: no name re-definition.
const slot = [null];
let n = 0;
for (let i = 0; i < 20000; i++) { slot[0] = (x) => x + 1; n += slot[0](i) & 1; }
print(n);
