//! Exec integration tests: typescript.
const std = @import("std");
const helpers = @import("../harness.zig");

// ---------------------------------------------------------------------------
// TypeScript as a first-class grammar: every case below is a module so the
// declarations stay isolated, and every case asserts its own runtime result.
// The parser grammar is TypeScript's; the same paths parse plain JavaScript.
// ---------------------------------------------------------------------------

const typescript_runtime_cases = [_][]const u8{
    // type-level declarations disappear
    \\interface Point { x: number; y: number }
    \\type Pair<T> = [T, T];
    \\type Cond<T> = T extends string ? "s" : "n";
    \\type Mapped = { readonly [K in "a" | "b"]?: number };
    \\type Tpl = `prefix-${string}`;
    \\type Fn = (a: number, ...rest: string[]) => void;
    \\type Ctor = abstract new () => object;
    \\type Inf<T> = T extends Array<infer U extends string> ? U : never;
    \\declare const ambient: number;
    \\declare function ambientFn(x: number): string;
    \\declare class AmbientClass<T> extends Object { m(): T; }
    \\declare module "somewhere" { export const y: number; }
    \\declare global { interface Window { foo: number } }
    \\declare namespace NS.Inner { const z: number; }
    \\assert.sameValue(typeof ambient, "undefined");
    ,
    // annotations on bindings, parameters, returns, catch, for heads
    \\let a: number = 1, b: string = "s";
    \\var v: number;
    \\let definite!: string;
    \\const { p, q }: { p: number; q: number } = { p: 1, q: 2 };
    \\const [t0, t1]: [number, number] = [3, 4];
    \\function f(x: number, y?: string, z: boolean = true, ...rest: number[]): number { return x + rest.length; }
    \\function g({ m }: { m: number }, [n]: number[] = [5]): number { return m + n; }
    \\function h(this: object, cb: (e: string) => void): void { cb("x"); }
    \\const arrow = (x: number): (y: number) => number => (y) => x + y;
    \\const generic = <T,>(x: T): T => x;
    \\const asyncArrow = async <T>(x: T): Promise<T> => x;
    \\for (let i: number = 0; i < 1; i++) { a += i; }
    \\try { throw 1; } catch (e: unknown) { a += 1; }
    \\assert.sameValue(a + t0 + t1, 9);
    \\assert.sameValue(p + q, 3);
    \\assert.sameValue(f(1, "y", false, 2, 3), 3);
    \\assert.sameValue(g({ m: 1 }), 6);
    \\assert.sameValue(arrow(1)(2), 3);
    \\assert.sameValue(generic(7), 7);
    \\assert.sameValue(typeof definite, "undefined");
    \\let calls = 0; h.call({}, (e) => { calls += e.length; }); assert.sameValue(calls, 1);
    ,
    // expression-level erasure: as, satisfies, !, <T>expr, generics on calls
    \\const n = (1 as unknown) as number;
    \\const obj = { k: 1 } satisfies Record<string, number>;
    \\const frozen = { a: 1 } as const;
    \\let maybe: string | undefined = "hi";
    \\const len = maybe!.length;
    \\const cast = <number>(<any>"5");
    \\const constCast = <const>["a"];
    \\function id<T>(x: T): T { return x; }
    \\const r = id<number>(3);
    \\const inst = id<string>;
    \\const m = new Map<string, Array<{ k: number }>>();
    \\const tagged = ((s: TemplateStringsArray) => s[0])<string>`tpl`;
    \\const opt = m?.get<any>("x");
    \\const chained = ({ deep: { v: 4 } } as { deep: { v: number } }).deep!.v;
    \\assert.sameValue(n, 1); assert.sameValue(obj.k, 1); assert.sameValue(frozen.a, 1);
    \\assert.sameValue(len, 2); assert.sameValue(cast, "5"); assert.sameValue(constCast[0], "a");
    \\assert.sameValue(r, 3); assert.sameValue(inst, id); assert.sameValue(m.size, 0);
    \\assert.sameValue(tagged, "tpl"); assert.sameValue(opt, undefined); assert.sameValue(chained, 4);
    ,
    // the three grammar divergences are resolved the tsc way
    \\const lt = (1 < 2) && (3 > 2);
    \\let x = 4, y = 2, z = 3;
    \\const cmp = x < y > z;
    \\const shifts = x >>> 0 < y >>> 0;
    \\const ge = x < y >= z;
    \\const tern = false ? 0 : (q: number): number => q + 1;
    \\const cond = true ? (y) : z;
    \\const call = ((a: number) => a)<number>(9);
    \\assert.sameValue(lt, true); assert.sameValue(cmp, false); assert.sameValue(shifts, false);
    \\assert.sameValue(ge, false); assert.sameValue(tern(1), 2); assert.sameValue(cond, 2); assert.sameValue(call, 9);
    ,
    // classes: modifiers, fields, overloads, abstract, implements, generics
    \\interface I { run(): number }
    \\abstract class Base<T> implements I {
    \\    abstract run(): number;
    \\    protected abstract2?(): void;
    \\    declare ghost: number;
    \\    [key: string]: unknown;
    \\    private static count: number = 0;
    \\    static readonly Z: number = 3;
    \\    public x?: number;
    \\    private y!: string;
    \\    readonly r = 1;
    \\    #p?: number = 2;
    \\    static #s: number;
    \\    over(x: string): string;
    \\    over(x: number): number;
    \\    over(x: any): any { return x; }
    \\    constructor(public name: string, protected size?: number, override readonly tag = "t") {}
    \\    m<U>(u: U): U { return u; }
    \\    get v(): number { return this.r; }
    \\    set v(n: number) {}
    \\    private async am(): Promise<void> {}
    \\    private *gen(): Generator<number> { yield 1; }
    \\    static s(): void {}
    \\    private static ps(): void {}
    \\    private ["computed"](): number { return 9; }
    \\    ["typed"]: number = 8;
    \\    protected constructorLike?: () => void;
    \\}
    \\class Impl extends Base<string> { run(): number { return 1; } override toString(): string { return "impl"; } }
    \\class Derived extends Object { constructor(private inner: number) { super(); } get(): number { return this.inner; } }
    \\const impl = new Impl("nm", 2);
    \\assert.sameValue(impl.run(), 1); assert.sameValue(String(impl), "impl");
    \\assert.sameValue(impl.name, "nm"); assert.sameValue(impl.size, 2); assert.sameValue(impl.tag, "t");
    \\assert.sameValue(impl.over("s"), "s"); assert.sameValue(impl.m(5), 5); assert.sameValue(impl.v, 1);
    \\assert.sameValue("ghost" in impl, false); assert.sameValue("x" in impl, true); assert.sameValue(impl.x, undefined);
    \\assert.sameValue(impl["computed"](), 9); assert.sameValue(impl["typed"], 8); assert.sameValue(Base.Z, 3);
    \\assert.sameValue(new Derived(7).get(), 7);
    ,
    // enum: auto-increment, constant folding, strings, references, runtime members
    \\enum Color { Red, Green = 5, Blue, Name = "nm" }
    \\const enum Dir { Up = -1, Down }
    \\enum Flags { A = 1 << 0, B = 1 << 1, AB = A | B, Neg = ~0, Str = "x" + "y", Tpl = `t` }
    \\enum Ref { A = 1, B = A * 2, C = Ref.B + 1, D = 1.5 }
    \\let counter = 40;
    \\enum Rt { A = counter + 2, B = "b" }
    \\enum Keys { "with space" = 1, default = 2 }
    \\assert.sameValue(Color.Red, 0); assert.sameValue(Color[5], "Green"); assert.sameValue(Color.Blue, 6);
    \\assert.sameValue(Color.Name, "nm"); assert.sameValue(Color["Name"], "nm"); assert.sameValue(Color[0], "Red");
    \\assert.sameValue(Dir.Up, -1); assert.sameValue(Dir.Down, 0);
    \\assert.sameValue(Flags.AB, 3); assert.sameValue(Flags.Neg, -1); assert.sameValue(Flags.Str, "xy"); assert.sameValue(Flags.Tpl, "t");
    \\assert.sameValue(Ref.C, 3); assert.sameValue(Ref.D, 1.5); assert.sameValue(Ref[1.5], "D");
    \\assert.sameValue(Rt.A, 42); assert.sameValue(Rt[42], "A"); assert.sameValue(Rt.B, "b");
    \\assert.sameValue(Keys["with space"], 1); assert.sameValue(Keys.default, 2);
    ,
    // namespaces, module keyword, dotted nesting, import aliases
    \\namespace NS { export const v = 1; export namespace Inner { export enum E { A } } export function fn() { return 2; } export class K {} export type T = number; export interface I {} }
    \\module Legacy { export const w = 3; }
    \\namespace A.B { export const c = 4; }
    \\import Alias = NS.Inner.E;
    \\export import Exported = A.B;
    \\assert.sameValue(NS.v, 1); assert.sameValue(NS.Inner.E.A, 0); assert.sameValue(NS.fn(), 2);
    \\assert.sameValue(typeof NS.K, "function"); assert.sameValue(Legacy.w, 3); assert.sameValue(A.B.c, 4);
    \\assert.sameValue(Alias.A, 0); assert.sameValue(Exported.c, 4);
    ,
    // type-only import/export forms leave no runtime trace
    \\import type { Nothing } from "./does-not-exist";
    \\export type { Nothing };
    \\export type Alias = number;
    \\export interface Shape { s: number }
    \\export declare const declared: number;
    \\export abstract class Ab {}
    \\export enum En { X }
    \\export namespace Space { export const s = 1; }
    \\export const value = 1;
    \\export { type Gone as Renamed, value as other };
    \\export function overloaded(a: string): void;
    \\export function overloaded(a: any): void {}
    \\assert.sameValue(En.X, 0); assert.sameValue(Space.s, 1);
    ,
    // contextual keywords remain ordinary identifiers in JavaScript positions
    \\var type = 1, declare = 2, namespace = 3, abstract = 4, as = 5, satisfies = 6, readonly = 7, keyof = 8;
    \\const o = { type, declare, as, satisfies, get: 1, set: 2, readonly, async: 3, static: 4 };
    \\class C { type = 1; declare = 2; static = 3; readonly = 4; abstract = 5; override = 6; get = 7; async = 8; accessor = 9; static static() { return 10; } }
    \\const c = new C();
    \\assert.sameValue(type + declare + namespace + abstract + as + satisfies + readonly + keyof, 36);
    \\assert.sameValue(o.type + o.declare + o.as + o.satisfies + o.readonly, 21);
    \\assert.sameValue(c.type + c.declare + c.static + c.readonly + c.abstract + c.override + c.get + c.async + c.accessor, 45);
    \\assert.sameValue(C.static(), 10);
    ,
    // review regressions: namespace re-opening and merging, abstract fields,
    // parenthesized arrow return types, string-literal enum names, type exports
    \\namespace A.B.C { export const x = 1; }
    \\namespace A.B { export const y = 2; }
    \\assert.sameValue(Object.keys(A.B).join(), "C,y");
    \\class K { static s = 1; }
    \\namespace K { export const t = 2; }
    \\assert.sameValue(K.s + K.t, 3);
    \\abstract class Base { abstract p: number; q = 1; }
    \\class Derived extends Base { p = 2; }
    \\assert.sameValue(Object.keys(new Derived()).join(), "q,p");
    \\const adder = (x: number): ((y: number) => number) => (y) => x + y;
    \\const none = (): (() => void) => () => {};
    \\assert.sameValue(adder(1)(2), 3); assert.sameValue(typeof none(), "function");
    \\enum Named { ["a"] = 1, [`b`] = 2 }
    \\assert.sameValue(Named.a + Named.b, 3);
    \\interface Local {}
    \\export { Local };
    ,
    // namespace/enum members resolve to the object (tsc rewrites), and
    // parameter properties are fields defined ahead of declared fields
    \\namespace Live { export function bump() { counter++; total += 10; } export let counter = 1; export var total = 0; }
    \\Live.bump(); Live.counter = 5; Live.bump();
    \\assert.sameValue(Live.counter, 6); assert.sameValue(Live.total, 20);
    \\namespace Split { export const first = 1; }
    \\namespace Split { export const second = first + 1; }
    \\assert.sameValue(Split.second, 2);
    \\namespace Outer { export const base = 10; export namespace Inner { export const derived = base + 1; } }
    \\assert.sameValue(Outer.Inner.derived, 11);
    \\namespace Shadow { export const v = 1; export function get(v: number) { return v; } }
    \\assert.sameValue(Shadow.get(7), 7);
    \\const Seven = () => 7;
    \\enum Runtime { X = Seven(), Y = X * 2 }
    \\enum Runtime { Z = Y + 1 }
    \\const A = 100;
    \\enum Merged { A = 2 }
    \\enum Merged { B = A * 3 }
    \\assert.sameValue(Runtime.Y, 14); assert.sameValue(Runtime.Z, 15); assert.sameValue(Merged.B, 6);
    \\const setterCalls: number[] = [];
    \\class Setter { set y(v: number) { setterCalls.push(v); } }
    \\class Props extends Setter { x = 1; constructor(public y: number, readonly z = 3) { super(); } }
    \\const props = new Props(5);
    \\assert.sameValue(Object.keys(props).join(), "y,z,x"); assert.sameValue(setterCalls.length, 0);
    ,
    // erased computed members (overloads, optional and abstract members,
    // abstract accessors) never evaluate their key; type members may be
    // computed accessors
    \\const evaluated: string[] = [];
    \\const key = (k: string) => { evaluated.push(k); return k; };
    \\abstract class Erased {
    \\  [key("overload")](x: number): void;
    \\  [key("method")](x: any) { return x; }
    \\  [key("optional")]?(): void;
    \\  abstract [key("abstractMethod")](): void;
    \\  abstract [key("abstractField")]: number;
    \\  abstract get [key("abstractGetter")](): number;
    \\  abstract set [key("abstractSetter")](v: number);
    \\  [key("field")]?: number;
    \\}
    \\assert.sameValue(evaluated.join(), "method,field");
    \\interface Accessors { get ["x"](): number; set [Symbol.iterator](v: number); }
    \\type AccessorLiteral = { get [Symbol.iterator](): number };
    ,
};

test "TypeScript grammar: runtime behaviour of erased and lowered syntax" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    for (typescript_runtime_cases, 0..) |source, index| {
        var name_buffer: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name_buffer, "ts-case-{d}.ts", .{index});
        const result = js.evalWithOptions(source, .{ .mode = .module, .filename = filename }) catch |err| {
            std.debug.print("TypeScript case {d} failed: {s}\n{s}\n", .{ index, @errorName(err), source });
            return err;
        };
        try std.testing.expect(!result.is(.exception));
    }
}

const typescript_rejected_cases = [_]struct { src: []const u8, needle: []const u8 }{
    .{ .src = "@dec class C {}", .needle = "decorators" },
    .{ .src = "class C { @dec m() {} }", .needle = "decorators" },
    .{ .src = "class C { constructor(@Inject() x: number) {} }", .needle = "decorators" },
    .{ .src = "import fs = require(\"fs\");", .needle = "not supported" },
    .{ .src = "export = 1;", .needle = "not supported" },
    .{ .src = "function f(a: string): void;\nlet x = 1;", .needle = "implementation is missing" },
    .{ .src = "class C { m(): void; }", .needle = "implementation is missing" },
    .{ .src = "enum E { A = \"a\", B }", .needle = "initializer" },
    .{ .src = "class C { accessor x = 1; }", .needle = "not supported" },
    .{ .src = "abstract class C { abstract x = 1; }", .needle = "abstract property" },
    .{ .src = "export { missing };", .needle = "'missing'" },
};

test "TypeScript grammar: unsupported forms are rejected with a clear message" {
    const js = helpers.sharedTestEngine();
    defer helpers.endSharedTest();

    for (typescript_rejected_cases, 0..) |case, index| {
        var name_buffer: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name_buffer, "ts-reject-{d}.ts", .{index});
        var failed = false;
        _ = js.evalWithOptions(case.src, .{ .mode = .module, .filename = filename }) catch |err| switch (err) {
            error.SyntaxError, error.JSException => failed = true,
            else => return err,
        };
        try std.testing.expect(failed);
        var exception = try js.takeExceptionInfo();
        defer exception.deinit();
        const message = try exception.getMessage(std.testing.allocator);
        defer std.testing.allocator.free(message);
        if (std.mem.indexOf(u8, message, case.needle) == null) {
            std.debug.print("TypeScript reject case {d}: message '{s}' lacks '{s}'\n", .{ index, message, case.needle });
            return error.TestUnexpectedResult;
        }
    }
}
