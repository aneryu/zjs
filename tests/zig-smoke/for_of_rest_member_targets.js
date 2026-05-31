// for-of destructuring writes rest results through member assignment targets.
var target = {};
for ({a: target.value} of [{a: 1}, {a: 2}]) {}
print(target.value);

var obj = {};
for ({a: [...obj.rest]} of [{a: [3, 4]}]) {}
print(obj.rest.join(","));
