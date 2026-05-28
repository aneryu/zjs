// Date object smoke tests
console.log(typeof Date());
console.log(typeof new Date());
console.log(Date.UTC(2024, 0, 1));
console.log(Date.UTC(99, 0, 1));
const local = new Date(2024, 0, 2, 3, 4, 5, 6);
console.log(local.getFullYear());
console.log(local.getMonth());
console.log(local.getDate());
console.log(local.getHours());
console.log(local.getMinutes());
console.log(local.getSeconds());
console.log(local.getMilliseconds());
const d = new Date(1704067200000);
console.log(typeof d);
console.log(d.getTime());
console.log(d.valueOf());
const epoch = new Date(0);
console.log(typeof epoch.toISOString);
console.log(epoch.toISOString());
console.log(typeof epoch.toJSON);
console.log(epoch.toJSON());
console.log(epoch.getUTCFullYear());
console.log(epoch.getUTCMonth());
console.log(epoch.getUTCDate());
console.log(epoch.getUTCHours());
console.log(epoch.getUTCMinutes());
console.log(epoch.getUTCSeconds());
console.log(epoch.getUTCMilliseconds());
console.log(epoch.getUTCDay());
try {
  Date.prototype.getTime.call({});
} catch (e) {
  console.log(e.name + ": " + e.message);
}
try {
  new Date(NaN).toISOString();
} catch (e) {
  console.log(e.name + ": " + e.message);
}
console.log(new Date(NaN).toJSON());
const now = Date.now();
console.log(typeof now);
console.log(now > 0);
console.log(Date.parse("2024-01-01T00:00:00Z"));
console.log(Date.parse("2024-01-01T12:34:56.789Z"));
