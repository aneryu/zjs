// $262.evalScript runs host script code and returns the script completion.
print($262.evalScript("var hostEval = 41; hostEval + 1;"));
print(hostEval);
print(typeof $262.gc);
print($262.gc.length);
print($262.gc());

var realm = $262.createRealm();
print(realm.evalScript("var realmEval = 3; realmEval + 4;"));
print(typeof realmEval);
