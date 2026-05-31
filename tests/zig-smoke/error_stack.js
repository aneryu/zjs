function outer() {
  return middle();
}

function middle() {
  return inner();
}

function inner() {
  return new Error("boom").stack;
}

var stack = outer();
console.log(typeof stack);
console.log(stack.indexOf("at inner") >= 0);
console.log(stack.indexOf("at middle") >= 0);
console.log(stack.indexOf("at outer") >= 0);
console.log(stack.indexOf("error_stack.js") >= 0);
console.log(new Error("x").propertyIsEnumerable("stack"));

Error.stackTraceLimit = 2;
var limited = outer();
console.log(limited.split("\n").length);

Error.stackTraceLimit = 10;
function nativeThrow() {
  try {
    null.x;
  } catch (err) {
    return typeof err.stack === "string" && err.stack.indexOf("at nativeThrow") >= 0;
  }
}
console.log(nativeThrow());

Error.prepareStackTrace = function (err, sites) {
  console.log(err.message);
  console.log(sites.length >= 2);
  console.log(sites[0].getFunctionName());
  console.log(sites[0].getFileName().indexOf("error_stack.js") >= 0);
  console.log(typeof sites[0].getLineNumber());
  console.log(typeof sites[0].getColumnNumber());
  console.log(sites[0].getLineNumber() > 1);
  console.log(sites[0].isConstructor());
  console.log(sites[0].toString().indexOf("inner") >= 0);
  return "prepared:" + sites[0].getFunctionName();
};
console.log(outer() === "prepared:inner");

Error.prepareStackTrace = undefined;
function captureOuter() {
  return captureSkip();
}

function captureSkip() {
  var target = {};
  Error.captureStackTrace(target, captureSkip);
  console.log(typeof target.stack);
  console.log(target.propertyIsEnumerable("stack"));
  console.log(target.stack.indexOf("captureSkip") < 0);
  console.log(target.stack.indexOf("captureOuter") >= 0);
  return target.stack;
}

captureOuter();

Error.prepareStackTrace = function () {
  throw new TypeError("prep");
};
console.log(new Error("x").stack === null);
Error.prepareStackTrace = undefined;
