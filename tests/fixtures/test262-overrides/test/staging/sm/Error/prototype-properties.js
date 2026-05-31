// Copyright (C) 2024 Mozilla Corporation. All rights reserved.
// This code is governed by the BSD license found in the LICENSE file.

/*---
description: |
  pending
esid: pending
---*/

const nativeErrors = [
    EvalError,
    RangeError,
    ReferenceError,
    SyntaxError,
    TypeError,
    URIError
];

const ownKeys = Reflect.ownKeys(Error.prototype);
for (const expected of ["constructor", "message", "name", "toString"]) {
  assert.sameValue(ownKeys.includes(expected), true, "Error.prototype should have a key named " + expected);
}
assert.sameValue(Error.prototype.name, "Error");
assert.sameValue(Error.prototype.message, "");

var nativeErrorSubclasses = nativeErrors.filter(function(error) {
    return error !== Error;
});

for (const error of nativeErrorSubclasses) {
    assert.sameValue(Reflect.ownKeys(error.prototype).sort().toString(), "constructor,message,name");
    assert.sameValue(error.prototype.name, error.name);
    assert.sameValue(error.prototype.message, "");
    assert.sameValue(error.prototype.constructor, error);
}
