(function () {
    var value = 0;
    var sum = 0;
    for (var i = 0; i < 10000000; i++) {
        value = i & 1;
        sum = (sum + value) | 0;
    }
    print(sum);
})();
