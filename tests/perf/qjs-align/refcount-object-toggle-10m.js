(function () {
    var left = {};
    var right = {};
    var value = left;
    var sum = 0;
    for (var i = 0; i < 10000000; i++) {
        value = (i & 1) === 0 ? left : right;
        if (value === left) sum++;
    }
    print(sum);
})();
