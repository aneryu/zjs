// J6: reading a symbol-keyed property that lives on the prototype chain --
// exactly the lookup `instanceof` performs for @@hasInstance before it can
// decide whether the ordinary algorithm applies. Pairs with J4 (a string-keyed
// read of the same shape) to separate symbol-key handling from property
// lookup in general.
var N = 15000000;
function main(n) {
    function C() {}
    var k = Symbol.hasInstance;
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (C[k]) s++;
    }
    return s;
}
print(main(N));
