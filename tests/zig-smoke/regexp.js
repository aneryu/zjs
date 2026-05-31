// RegExp object smoke tests
const r = new RegExp("a", "g");
console.log(typeof r);
console.log(r.toString());
console.log(r.test("a"));
console.log(r.exec("a"));
console.log(RegExp.test("a", "a"));
console.log(RegExp.exec("a", "a"));
