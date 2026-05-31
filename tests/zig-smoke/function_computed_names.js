var obj = {
  ["func"]: function() {},
  ["anonClass"]: class {},
  [1]: function() {},
  [2]: class {},
  3: class {},
};

print([obj.func.name, obj.anonClass.name, obj[1].name, obj[2].name, obj[3].name].join("|"));

let C = class {
  ["arrowFunc"] = () => {}
  ["asyncArrowFunc"] = async () => {};
};
let c = new C();
print([c.arrowFunc.name, c.asyncArrowFunc.name, Object.getOwnPropertyNames(c).join("|")].join("|"));

function checkSyntaxError(source) {
  try {
    eval(source);
    print("accepted");
  } catch (e) {
    print(e.name);
  }
}

checkSyntaxError("var f = () => {}();");
checkSyntaxError("var f = () => {}['name'];");
