// J4: the `.prototype` read that the ordinary instanceof algorithm performs on
// its right operand every time (quickjs.c:8078). Prices that single property
// fetch on its own.
var N = 15000000;
function main(n) {
    function C() {}
    var s = 0;
    for (var i = 0; i < n; i++) {
        if (C.prototype) s++;
    }
    return s;
}
print(main(N));
