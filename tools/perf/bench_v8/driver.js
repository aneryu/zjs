var success = true;
function PrintResult(name, result) { print(name + ': ' + result); }
function PrintError(name, error) { PrintResult(name, 'ERROR: ' + error); success = false; }
function PrintScore(score) {
    if (success) { print('----'); print('Score (version ' + BenchmarkSuite.version + '): ' + score); }
}
// zlib is skip-listed pending a zjs engine fix: it throws inside its giant
// indirect eval() of emscripten-generated code (docs/perf/bench-v8-status.md).
BenchmarkSuite.RunSuites({ NotifyResult: PrintResult, NotifyError: PrintError, NotifyScore: PrintScore }, ['zlib']);
