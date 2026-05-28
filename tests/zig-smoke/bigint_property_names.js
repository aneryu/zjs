var data = {
  1_2_3n: "separator",
  0xan: "hex",
  4294967296n: "wide",
};
print(data[123]);
print(data[10]);
print(data["4294967296"]);

var methods = {
  1n() {},
  *2n() {},
  async 3n() {},
  async* 4n() {},
  get 5n() { return 5; },
  set 6n(value) {},
};
print([
  methods[1].name,
  methods[2].name,
  methods[3].name,
  methods[4].name,
  Object.getOwnPropertyDescriptor(methods, 5).get.name,
  Object.getOwnPropertyDescriptor(methods, 6).set.name,
].join("|"));

var inferred = {
  0xan: function() {},
};
print(inferred[10].name);

class C {
  static 1n() {}
  2n() {}
}
print(C[1].name + "|" + C.prototype[2].name);
