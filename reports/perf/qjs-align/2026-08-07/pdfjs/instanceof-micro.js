// Mirrors boyer's shape: `p instanceof sc_Pair` where p is an instance (hit)
// or a different type (miss). MODE picks which; both engines run identical work.
function Ctor() { this.a = 1; }
function Other() { this.b = 2; }
var MODE = scriptArgs[1];
var hit = new Ctor(), miss = new Other();
var obj = (MODE === "miss") ? miss : hit;
var n = 0, ITERS = 4000000;
for (var i = 0; i < ITERS; i++) { if (obj instanceof Ctor) n++; }
print(MODE + " n=" + n);
