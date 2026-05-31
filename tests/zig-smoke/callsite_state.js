// CallSite metadata is internal state.
Error.prepareStackTrace = function (err, sites) {
  var site = sites[0];
  print("__zjs_callsite" in site);
  print("__zjs_callsite_line" in site);
  print(typeof site.getFunction);
  print(typeof site.getThis);
  print(site.hasOwnProperty("getFunction"));
  print(site.toString());
  print(Object.prototype.toString.call(site));
  print(site[Symbol.toStringTag]);
  var name = site.getFunctionName();
  var file = site.getFileName();
  var line = site.getLineNumber();
  var column = site.getColumnNumber();
  site.__zjs_callsite_function = "fakeFn";
  site.__zjs_callsite_file = "fake.js";
  site.__zjs_callsite_line = 999;
  site.__zjs_callsite_column = 777;
  print(site.getFunctionName() === name);
  print(site.getFileName() === file);
  print(site.getLineNumber() === line);
  print(site.getColumnNumber() === column);
  print(site.toString().indexOf("fake") < 0);
  return "ok";
};

function inner() {
  return new Error("x").stack;
}

print(inner());
Error.prepareStackTrace = undefined;
