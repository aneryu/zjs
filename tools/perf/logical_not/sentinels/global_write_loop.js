// P7-61 collateral sentinel wrapper: the checked-in same-runtime case
// `tools/perf/same_runtime/cases/global_write_loop.js` verbatim, driven 800 times.
// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// the strict loop and top-level global remain, wrapped in retained run().
var g = 0;

function run() {
    "use strict";
    g = 0;
    for (let i = 0; i < 100000; i++) g = i;
    return g;
}

var acc = 0;
for (var rep = 0; rep < 800; rep++) acc += run();
print(acc);
