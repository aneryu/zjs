// AsyncGenerator prototype method dispatch markers are internal metadata.
async function* g() {}
var AsyncGeneratorPrototype = Object.getPrototypeOf(g.prototype);
var next = AsyncGeneratorPrototype.next;

print("__zjs_async_generator_method" in next);
print(Object.getOwnPropertyDescriptor(next, "__zjs_async_generator_method") === undefined);

next.__zjs_async_generator_method = 0;
print("__zjs_async_generator_method" in next);
print(delete next.__zjs_async_generator_method);
print("__zjs_async_generator_method" in next);
