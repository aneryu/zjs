// C5: native -> JS callback from String.prototype.replace with a global regexp (2 callbacks per iteration).
var N = 2000000;
function main(n) {
    var str = "xaxbx";
    var s = 0;
    var fn = function (m) { return "y"; };
    for (var i = 0; i < n; i++) { s += i + str.replace(/a|b/g, fn).length; }
    return s;
}
print(main(N));
