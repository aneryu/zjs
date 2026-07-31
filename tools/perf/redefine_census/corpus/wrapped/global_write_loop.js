// Provenance: callable adaptation of tools/compare/hotpath_cases.js;
// the strict loop and top-level global remain, wrapped in retained run().
var g = 0;

function run() {
    "use strict";
    g = 0;
    for (let i = 0; i < 100000; i++) g = i;
    return g;
}
print(run());
