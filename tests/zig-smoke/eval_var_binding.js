// eval-created var bindings are visible, deletable, and capturable.
var capture;
eval("var globalEval = 8; capture = function(){ return globalEval; };");
print(globalEval);
print(capture());
print(delete globalEval);
try { print(capture()); } catch (e) { print(e instanceof ReferenceError); }

function localEvalDelete() {
    eval("var localEval = 5");
    print(localEval);
    print(delete localEval);
    try { print(localEval); } catch (e) { print(e instanceof ReferenceError); }
}

localEvalDelete();
