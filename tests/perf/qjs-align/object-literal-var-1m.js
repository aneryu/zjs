(function () {
    var sum = 0;
    for (var i = 0; i < 1000000; i++) {
        var object = { value: i };
        sum = (sum + object.value) | 0;
    }
    print(sum);
})();
