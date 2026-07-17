(function () {
    var sum = 0;
    for (var i = 0; i < 2000000; i++) {
        var object = {};
        if (object) sum = (sum + (i & 1)) | 0;
    }
    print(sum);
})();
