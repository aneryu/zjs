import { value } from "./module_auto_detect_dep.js";

function metaCarrier() {
  return import.meta.url.indexOf("function_internal_slots.js") >= 0;
}

function makeEvalClosure() {
  var captured = value;
  return eval("(function inner(){ return captured; })");
}

var inner = makeEvalClosure();

console.log(Object.getOwnPropertyNames(metaCarrier).indexOf("__zjs_import_meta") === -1);
console.log(metaCarrier());
console.log(Object.getOwnPropertyNames(inner).indexOf("__zjs_eval_parent_function") === -1);
console.log(inner());
