// W0: fresh empty object per iteration, no writes -- the control for W1.
// (W1 - W0) / 3 prices one NEW own data property write (the put_field
// own-miss / prototype-walk / add-property path).
var N = 5000000;
function main(n) {
    var s = 0;
    for (var i = 0; i < n; i++) {
        var o = {};
        s += i;
    }
    return s;
}
print(main(N));
