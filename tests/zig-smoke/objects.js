const o = { a: 1, b: 2 };
print(o.a, o.b);

o.c = 3;
print(o.c);
print(Object.keys(o).join(","));
print(Object.values(o).join(","));
print(JSON.stringify(Object.entries(o)));
var keyOrder = "";
for (var k in o) keyOrder += k;
print(keyOrder);

const arr = [10, 20, 30];
print(arr[0], arr[1], arr[2]);
print(arr.length);

var roProto = {};
Object.defineProperty(roProto, "locked", { value: 1, writable: false, configurable: true });
var roObj = Object.create(roProto);
var roCaught = false;
try {
  roObj.locked = 2;
} catch (e) {
  roCaught = e instanceof TypeError;
}
print(roCaught, roObj.locked, Object.prototype.hasOwnProperty.call(roObj, "locked"));
var roStrictCaught = false;
try {
  (function() {
    "use strict";
    roObj.locked = 3;
  })();
} catch (e) {
  roStrictCaught = e instanceof TypeError;
}
print(roStrictCaught, roObj.locked, Object.prototype.hasOwnProperty.call(roObj, "locked"));

var accessorProto = {};
Object.defineProperty(accessorProto, "readOnlyAccessor", {
  get: function() { return 7; },
  configurable: true
});
var accessorObj = Object.create(accessorProto);
var accessorCaught = false;
try {
  accessorObj.readOnlyAccessor = 8;
} catch (e) {
  accessorCaught = e instanceof TypeError;
}
print(accessorCaught, accessorObj.readOnlyAccessor, Object.prototype.hasOwnProperty.call(accessorObj, "readOnlyAccessor"));
var accessorStrictCaught = false;
try {
  (function() {
    "use strict";
    accessorObj.readOnlyAccessor = 9;
  })();
} catch (e) {
  accessorStrictCaught = e instanceof TypeError;
}
print(accessorStrictCaught, accessorObj.readOnlyAccessor, Object.prototype.hasOwnProperty.call(accessorObj, "readOnlyAccessor"));

var writableProto = {};
Object.defineProperty(writableProto, "writableData", { value: 1, writable: true, configurable: true });
var writableObj = Object.create(writableProto);
writableObj.writableData = 9;
print(writableObj.writableData, Object.prototype.hasOwnProperty.call(writableObj, "writableData"));
