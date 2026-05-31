// Proxy.revocable stores its target in an internal revoker slot.
var r = Proxy.revocable({ x: 1 }, {});
var revoke = r.revoke;

print("__zjs_revoke_proxy" in revoke);
print(Object.getOwnPropertyDescriptor(revoke, "__zjs_revoke_proxy") === undefined);

revoke.__zjs_revoke_proxy = null;
print(revoke.__zjs_revoke_proxy === null);
revoke();

var threw = false;
try {
  r.proxy.x;
} catch (e) {
  threw = e instanceof TypeError;
}
print(threw);
print(delete revoke.__zjs_revoke_proxy);
print("__zjs_revoke_proxy" in revoke);

var r2 = Proxy.revocable({ y: 2 }, {});
print(delete r2.revoke.__zjs_revoke_proxy);
r2.revoke();

var threw2 = false;
try {
  r2.proxy.y;
} catch (e) {
  threw2 = e instanceof TypeError;
}
print(threw2);
r2.revoke();
print("done");
