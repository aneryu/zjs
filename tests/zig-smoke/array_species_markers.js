// Array species fast-path markers are internal and stable across user properties.
var getter = Object.getOwnPropertyDescriptor(Array, Symbol.species).get;
print("__zjs_array_constructor" in Array);
print(Object.getOwnPropertyDescriptor(Array, "__zjs_array_constructor") === undefined);
print("__zjs_array_species_getter" in getter);
print(Object.getOwnPropertyDescriptor(getter, "__zjs_array_species_getter") === undefined);

Array.__zjs_array_constructor = 0;
getter.__zjs_array_species_getter = 0;
var mapped = [1, 2].map(function(value) { return value + 1; });
print(mapped instanceof Array);
print(mapped.join(","));
print(delete Array.__zjs_array_constructor);
print(delete getter.__zjs_array_species_getter);
print([3].filter(function() { return true; }).join(","));
