// J5: instanceof that walks the receiver's whole chain and finds nothing, so
// it exits through the null-proto terminator instead of an early match. Pairs
// with J to separate a matching walk from a full-length failing walk.
var N = 15000000;
function main(n) {
    function A() {}
    function B() {}
    var o = new A();
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (o instanceof B) s++;
    }
    return s;
}
print(main(N));
