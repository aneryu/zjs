// Shell-compat shim. The emscripten-generated zlib benchmark (zlib-data.js)
// detects a "shell" environment (not browser / node / worker) and then
// evaluates `Module.read = read` eagerly, so the global must exist even
// though the benchmark never calls it (its input data is embedded). d8, the
// SpiderMonkey shell and jsc define read(path); QuickJS, Hermes and zjs do
// not. Define it identically for every engine so the composite stays
// comparable; it throws if anything ever does call it.
if (typeof read === 'undefined') {
  this.read = function (path) { throw new Error('read() is a bench-v8 shell shim; not implemented: ' + path); };
}
var success = true;
function PrintResult(name, result) { print(name + ': ' + result); }
function PrintError(name, error) { PrintResult(name, 'ERROR: ' + error); success = false; }
function PrintScore(score) {
    if (success) { print('----'); print('Score (version ' + BenchmarkSuite.version + '): ' + score); }
}
BenchmarkSuite.RunSuites({ NotifyResult: PrintResult, NotifyError: PrintError, NotifyScore: PrintScore });
