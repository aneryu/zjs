// CodeLoad micro — ATOM mode: per-iteration unique identifiers, fixed width.
//
// Same runtime throughout. Each iteration renames the goog / jQuery
// identifier families with a zero-padded 8-digit salt, so the source length
// is invariant across iterations while every iteration interns a fresh set
// of identifier atoms; the throw-gated indirect eval (see mode_compile.js)
// then releases all compile artifacts, exercising intern hit + miss +
// free-slot recycling. This mode adjudicates cut B.
//
// Uniquify uses a precomputed split + join, NOT RegExp.replace: the regexp
// engine (a large zjs advantage) must stay out of an atom-churn measurement.
//
// Requires payload_octane_codeload.js prepended (defines BASE_JS, JQUERY_JS).
//
// Atom-table live count / capacity / free-slot telemetry is not exposed to
// JS; when the B2 prototype is adjudicated, collect it with a scratch probe
// build as the B2 contract requires.
// ITERS is fixed by calibration (zjs ~1.8s at df214576); do not parameterize.
var ITERS = 120;
var indirectEval = eval;
(function () {
  var baseParts = BASE_JS.split("goog");
  var jqParts = JQUERY_JS.split("jQuery");
  function pad8(n) {
    var s = "" + n;
    while (s.length < 8) s = "0" + s;
    return s;
  }
  var ok = 0;
  for (var i = 0; i < ITERS; i++) {
    var g = "goog" + pad8(i);
    var j = "jQuery" + pad8(i);
    var srcClosure = "throw 0;var " + g + "salt=0;" + baseParts.join(g) +
        "(function(){return " + g + ".cloneObject(" + g + "salt);})();";
    var srcJQuery = "throw 0;var windowmock = {'document':new MockElement()," +
        "'location':{'href':''},'navigator':{'userAgent':''}};" +
        "var " + j + "Salt=0;" + jqParts.join(j) +
        "(function(){return windowmock." + j + ".grep([" + j + "Salt]," +
        "function(a,b){return true;})[0];})();";
    try { indirectEval(srcClosure); } catch (e) { if (e === 0) ok++; }
    try { indirectEval(srcJQuery); } catch (e) { if (e === 0) ok++; }
  }
  print("MODE: atom");
  print("ITERS: " + ITERS);
  print("CHECKSUM: " + ok + "/" + (2 * ITERS));
})();
