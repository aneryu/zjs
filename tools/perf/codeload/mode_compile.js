// CodeLoad micro — COMPILE mode: fixed payload, zero payload execution.
//
// Each iteration compiles the exact macro-benchmark source shape (Octane
// CodeLoad, salt pinned to 0, no cacheBust) as a GLOBAL program via indirect
// eval. A leading `throw 0;` stops execution right after
// GlobalDeclarationInstantiation, so what is measured is lex + parse +
// lowering + FunctionBytecode construction and its immediate release —
// never the library's own execution. The source bytes are identical every
// iteration, so the atom table reaches steady state after iteration 1 and
// this mode isolates compiler throughput (cuts A, C1-C4).
//
// Requires payload_octane_codeload.js prepended (defines BASE_JS, JQUERY_JS).
// ITERS is fixed by calibration (zjs ~1.7s at df214576); do not parameterize —
// a fixed workload is the point.
var ITERS = 120;
var indirectEval = eval;
(function () {
  var srcClosure = "throw 0;var googsalt=0;" + BASE_JS +
      "(function(){return goog.cloneObject(googsalt);})();";
  var srcJQuery = "throw 0;var windowmock = {'document':new MockElement()," +
      "'location':{'href':''},'navigator':{'userAgent':''}};" +
      "var jQuerySalt=0;" + JQUERY_JS +
      "(function(){return windowmock.jQuery.grep([jQuerySalt]," +
      "function(a,b){return true;})[0];})();";
  var ok = 0;
  for (var i = 0; i < ITERS; i++) {
    try { indirectEval(srcClosure); } catch (e) { if (e === 0) ok++; }
    try { indirectEval(srcJQuery); } catch (e) { if (e === 0) ok++; }
  }
  print("MODE: compile");
  print("ITERS: " + ITERS);
  print("CHECKSUM: " + ok + "/" + (2 * ITERS));
})();
