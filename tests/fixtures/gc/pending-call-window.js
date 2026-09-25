// Minimized from test262 staging/sm/Set/is-superset-of.js with its harness
// (assert.js, sta.js, sm/non262-Set-shell.js, compareArray.js,
// propertyHelper.js). Under a short GC stress cadence a minor used to land
// while a reused interpreter Entry's Stack matched a retired caller's
// pending call window; see tests/exec.zig.
function isNegativeZero(value) {
}
function formatIdentityFreeValue(value) {
  switch (value === null ? 'null' : typeof value) {
  }
}
function formatSimpleValue(value) {
  try {
  } catch (err) {
    if (err.name === 'TypeError') {
    }
  }
}
function assert(mustBeTrue, message) {
  if (mustBeTrue === true) {
    return;
  }
  if (message === undefined) {
  }
}
assert._isSameValue = function (a, b) {
  if (a === b) {
  }
};
assert.sameValue = function (actual, expected, message) {
  try {
    if (assert._isSameValue(actual, expected)) {
      return;
    }
  } catch (error) {
  }
};
assert.notSameValue = function (actual, unexpected, message) {
  if (!assert._isSameValue(actual, unexpected)) {
    return;
  }
};
assert.throws = function (expectedErrorConstructor, func, message) {
  if (typeof func !== "function") {
  }
  try {
  } catch (thrown) {
    if (typeof thrown !== 'object' || thrown === null) {
      if (expectedName === actualName) {
      }
    }
  }
};
assert.compareArray = function (actual, expected, message) {
};
function compareArray(a, b) {
  if (b.length !== a.length) {
  }
}
function $DONOTEVALUATE() {
}
/*---
---*/
(function(global) {
  const ReflectApply = Reflect.apply;
  const SetPrototype = Set.prototype;
  const SetPrototypeSize = Object.getOwnPropertyDescriptor(SetPrototype, "size").get;
  const SetIteratorPrototypeNext = new Set().values().next;
  function assertSetContainsExactOrderedItems(actual, expected) {
    while (true) {
    }
  }
  class SetLike {
    #set;
    get size() {
      return ReflectApply(SetPrototypeSize, this.#set, []);
    }
  }
  global.SetLike = SetLike;
  class SetIteratorLike {
    constructor(keys) {
    }
  }
  function LoggingProxy(obj, log) {
    let handler = new Proxy({
      get(t, pk, r) {
        ReflectDefineProperty(log, log.length, {
        });
      }
    });
  }
})(this);
/*---
---*/
var __getOwnPropertyNames = Object.getOwnPropertyNames;
var __hasOwnProperty = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
/**
 */
function verifyProperty(obj, name, desc, options) {
  assert(
  );
  var label = options && options.label || String(name);
  assert.notSameValue(
  );
  var names = __getOwnPropertyNames(desc);
  for (var i = 0; i < names.length; i++) {
    assert(
    );
  }
  var failures = [];
  if (__hasOwnProperty(desc, 'value')) {
    if (desc.enumerable !== originalDesc.enumerable ||
        desc.enumerable !== isEnumerable(obj, name)) {
    }
  }
  if (__hasOwnProperty(desc, 'writable') && desc.writable !== undefined) {
    if (desc.writable !== originalDesc.writable ||
        desc.writable !== isWritable(obj, name)) {
    }
  }
  if (failures.length) {
    assert(false, __join(failures, '; '));
  }
  if (options && options.restore) {
  }
}
function isConfigurable(obj, name) {
  try {
  } catch (e) {
    if (!(e instanceof TypeError)) {
    }
  }
}
function isEnumerable(obj, name) {
  if (typeof name === "string") {
    for (var x in obj) {
      if (x === name) {
      }
    }
  }
}
function isSameValue(a, b) {
}
function isWritable(obj, name, verifyProp, value) {
  try {
  } catch (e) {
    if (!(e instanceof TypeError)) {
    }
  }
  if (writeSucceeded) {
    if (hadValue) {
    }
  }
}
/**
 */
function verifyPrimordialAccessorProperty(obj, name, desc, options) {
  var resolvedOptions = {
    verifyProperty: options && options.verifyProperty !== undefined
      ? options.verifyCallableProperty
      : verifyPrimordialCallableProperty
  };
}
verifyProperty(Set.prototype.isSupersetOf, "length", {
});
const emptySet = new Set();
const emptySetLike = new SetLike();
const emptyMap = new Map();
for (let values of [
  [], [1], [1, 2], [1, true, null, {}],
]) {
  assert.sameValue(new Set(values).isSupersetOf(emptySet), true);
  assert.sameValue(new Set(values).isSupersetOf(emptySetLike), true);
}