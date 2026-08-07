


var N = (typeof scriptArgs != "undefined" && scriptArgs[1]) ? (scriptArgs[1]|0) : 8;
setupPdfJS();
for (var __i = 0; __i < N; __i++) runPdfJS();
tearDownPdfJS();
print("ok " + N);
