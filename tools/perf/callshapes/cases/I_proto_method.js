// I: method found on the prototype, not on the receiver.
var N = 12000000;
function main(n) {
    function K() { this.v = 1; }
    K.prototype.method = function () { return this.v; };
    var o = new K();
    var s = 0;
    for (var i = 0; i < n; i++) {
        s += o.method();
    }
    return s;
}
print(main(N));
