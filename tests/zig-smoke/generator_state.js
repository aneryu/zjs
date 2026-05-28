// Generator runtime state is internal metadata.
class Base {
  m() {
    return 10;
  }
}

class Derived extends Base {
  *g() {
    yield 1;
    return super.m();
  }
}

var generator = new Derived().g();
print("__zjs_generator_function" in generator);
print(generator.next().value);
function* fake() {}
generator.__zjs_generator_function = fake;
var resumed = generator.next();
print(resumed.done, resumed.value);

function* yieldStar() {
  yield* [1, 2];
  yield 3;
}

var delegated = yieldStar();
print("__zjs_generator_yield_star_suspended" in delegated);
print("__zjs_generator_resume_completion" in delegated);
print(delegated.next().value);
delegated.__zjs_generator_yield_star_suspended = true;
delegated.__zjs_generator_resume_completion = 2;
try {
  delegated.throw("x");
} catch (e) {
  print(e instanceof TypeError, e.name);
}
