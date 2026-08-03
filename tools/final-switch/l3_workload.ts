// FINAL SWITCH -- L3 emission workload (TypeScript lowering).
//
// The TypeScript constructs are separated from the JavaScript workload because
// they are the ones L3 actually caught falling back: enum, const enum,
// namespace, namespace-with-class, and parameter properties all lower to
// emitted code rather than being erased, and each lowering is a distinct
// emission path. Erased-only constructs (interface, type alias, annotations,
// generics, satisfies) are here too so that "erased" stays proven rather than
// assumed.

// --- erased: must produce no emission of their own --------------------------
interface Box<T> { value: T }
interface Box { extra?: string }
type Pair = [number, string];
const annotated: number = 1;
function typedFn(input: number): number { return input; }
function identity<T>(value: T): T { return value; }
const genericArrow = <T,>(value: T): T => value;
class Store<T> { value!: T }
const asserted = ({ count: 1 } as { count: number }) satisfies { count: number };

// --- lowered: these EMIT, and each is an L3 finding if it falls back --------
enum Direction { Up, Down = 4, Name = "name" }
const enum Flag { A = 1, B = 2 }
const flag: Flag = Flag.A;

namespace Basic { export const value = 1; }
namespace Nested.Inner { export const value = 2; }
namespace WithMembers {
  export const value = 3;
  // KNOWN GAP as of 04922a47, identical on BOTH backends and therefore
  // pre-existing rather than a switch regression: a function declaration
  // inside a namespace body is dropped entirely. It is neither attached to
  // the namespace object (`WithMembers.make` is `undefined`) nor bound as a
  // local inside the body (`typeof make` inside the namespace is also
  // `undefined`), so it cannot be called from anywhere. The declaration stays
  // because this workload measures what gets COMPILED, and the L3 gate must
  // keep seeing this lowering path; nothing calls it, and this note is why.
  export function make(): number { return value; }
  export class Item { run(): number { return value; } }
}
namespace Merged { export const value = 4; }
namespace Merged { export const other = 5; }

class ParameterProperties {
  constructor(
    public value: number,
    private label: string,
    readonly id: number,
  ) {}
  describe(): string { return this.label + this.value + this.id; }
}

// --- keep everything live ---------------------------------------------------
const total =
  annotated +
  typedFn(1) +
  identity(1) +
  genericArrow(1) +
  asserted.count +
  new Store<number>().value ? 1 : 1;

const emitted =
  total +
  Direction.Up + Direction.Down + String(Direction[4]).length +
  String(Direction.Name).length +
  flag + Flag.B +
  Basic.value + Nested.Inner.value +
  WithMembers.value + new WithMembers.Item().run() +
  Merged.value + Merged.other +
  new ParameterProperties(1, "x", 2).describe().length;

const box: Box<number> = { value: emitted };
const pair: Pair = [emitted, "ok"];
if (!(box.value > 0 && pair[1] === "ok")) throw new Error("ts l3 workload did not execute");
