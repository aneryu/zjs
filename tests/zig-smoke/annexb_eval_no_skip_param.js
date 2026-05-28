// Annex B direct eval block function publication with a same-name parameter.
var init, after;

(function(f) {
    eval("init = f; { function f() {} } after = f;");
}(123));

print(init);
print(typeof after);
print(after());
