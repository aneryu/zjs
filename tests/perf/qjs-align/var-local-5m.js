(function () {
    var sum = 0;
    for (var i = 0; i < 5000000; i++) {
        var value = i & 255;
        sum = (sum + value) | 0;
    }
    print(sum);
})();
