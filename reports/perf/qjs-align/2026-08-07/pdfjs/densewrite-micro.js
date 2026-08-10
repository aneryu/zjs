// int vs float dense in-range write, same array, same loop.
var MODE = scriptArgs[1];
var SIZE = 4096;
var a = new Array(SIZE);
var seedFloat = (MODE === "fwrite" || MODE === "fbase");
for (var i = 0; i < SIZE; i++) a[i] = seedFloat ? i * 0.5 : i;
var sink = 0, ITERS = 4000;
if (MODE === "iwrite")      { for (var k=0;k<ITERS;k++) for (var j=0;j<SIZE;j++) a[j] = 7; }
else if (MODE === "fwrite") { for (var k=0;k<ITERS;k++) for (var j=0;j<SIZE;j++) a[j] = 1.5; }
else if (MODE === "ibase")  { for (var k=0;k<ITERS;k++) for (var j=0;j<SIZE;j++) sink = 7; }
else                        { for (var k=0;k<ITERS;k++) for (var j=0;j<SIZE;j++) sink = 1.5; }
print(MODE + " " + a[7] + " " + sink);
