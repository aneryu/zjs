/* QuickJS twin of zjs_boundary_bench.zig: same cases, same JS loops, QuickJS C API.
 *
 * Usage: qjs-boundary-bench <case> [N]
 *        qjs-boundary-bench --list          (prints the supported case names, one per line)
 * Exit codes: 0 ok, 1 failure, 2 unsupported case (the sampler skips those).
 *
 * Cases (every JS loop is `function main(n) { var s = 0; for (...) { s += <op>; } return s }`;
 * the host loops run N iterations from C; the sampler subtracts ctrl / the N=0 baseline):
 *   ctrl            s += i
 *   builtin         abs(i)                      Math.abs hoisted to a local
 *   host2           host_add(i, 1)              JS_NewCFunction, 2 int args
 *   host0           (host_noop(), i)            JS_NewCFunction, 0 args, returns undefined
 *   leaf2           host_add(i, 1)              alias of host2: the qjs reference for zjs's typed leaf
 *   leaf_state      host_tick(i)                JS_NewCFunctionData, per-runtime state via JS_GetRuntimeOpaque
 *   method_typed    world.step(i)               opaque class (JS_NewClass + JS_SetOpaque), JS_GetOpaque2 unwrap, int in / int out
 *   method_managed  world.query(i)              same object, method returning a JSValue (argv[0] passthrough)
 *   getter_native   world.time                  JS_CGETSET_DEF getter reading an opaque field
 *   getter_typed    world.time                  alias of getter_native (qjs has one getter kind)
 *   n2j1 / site1    JS_Call(cb, [i]) N times    cb = function (x) { return x + 1 }
 *   n2j0 / site0    JS_Call(cb, []) N times     cb = function () {}
 *   prop_site       JS_GetPropertyStr(obj, "field") N times   obj = { x: 1, y: 2, field: 3 }
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

/* ---- host functions (host2 / host0 / leaf2) ---- */
static JSValue host_add(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    int32_t a, b;
    if (argc < 2) return JS_ThrowTypeError(ctx, "need 2 args");
    if (JS_ToInt32(ctx, &a, argv[0])) return JS_EXCEPTION;
    if (JS_ToInt32(ctx, &b, argv[1])) return JS_EXCEPTION;
    return JS_NewInt32(ctx, a + b);
}
static JSValue host_noop(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_UNDEFINED;
}

/* ---- leaf_state: per-runtime state reached through the runtime opaque ---- */
typedef struct HostState {
    int64_t ticks;
    int32_t step;
} HostState;

static JSValue host_tick(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv,
                         int magic, JSValue *func_data) {
    HostState *st = JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
    int32_t a;
    if (argc < 1) return JS_ThrowTypeError(ctx, "need 1 arg");
    if (JS_ToInt32(ctx, &a, argv[0])) return JS_EXCEPTION;
    st->ticks++;
    return JS_NewInt32(ctx, a + st->step);
}

/* ---- World: opaque class for method_typed / method_managed / getter_* ---- */
typedef struct World {
    int64_t steps;
    int64_t queries;
    int32_t stride;
    int32_t time_ms;
} World;

static JSClassID world_class_id;

static void world_finalizer(JSRuntime *rt, JSValue val) {
    World *w = JS_GetOpaque(val, world_class_id);
    free(w);
}

static const JSClassDef world_class = { "World", .finalizer = world_finalizer };

/* world.step(i): typed leaf shape -- unwrap, touch state, int in / int out. */
static JSValue world_step(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    World *w = JS_GetOpaque2(ctx, this_val, world_class_id);
    int32_t dt;
    if (!w) return JS_EXCEPTION;
    if (argc < 1) return JS_ThrowTypeError(ctx, "need 1 arg");
    if (JS_ToInt32(ctx, &dt, argv[0])) return JS_EXCEPTION;
    w->steps++;
    return JS_NewInt32(ctx, dt + w->stride);
}

/* world.query(i): managed shape -- unwrap, touch state, hand back a JSValue untouched. */
static JSValue world_query(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    World *w = JS_GetOpaque2(ctx, this_val, world_class_id);
    if (!w) return JS_EXCEPTION;
    if (argc < 1) return JS_ThrowTypeError(ctx, "need 1 arg");
    w->queries++;
    return JS_DupValue(ctx, argv[0]);
}

/* world.time: native getter reading one opaque field. */
static JSValue world_get_time(JSContext *ctx, JSValueConst this_val) {
    World *w = JS_GetOpaque2(ctx, this_val, world_class_id);
    if (!w) return JS_EXCEPTION;
    return JS_NewInt32(ctx, w->time_ms);
}

static const JSCFunctionListEntry world_proto_funcs[] = {
    JS_CFUNC_DEF("step", 1, world_step),
    JS_CFUNC_DEF("query", 1, world_query),
    JS_CGETSET_DEF("time", world_get_time, NULL),
};

static const char *const case_names[] = {
    "ctrl", "builtin", "host2", "host0",
    "leaf2", "leaf_state", "method_typed", "method_managed", "getter_native", "getter_typed",
    "n2j1", "n2j0", "site1", "site0", "prop_site",
};

static const char *loop(const char *op, char *buf) {
    sprintf(buf, "function main(n) { var s = 0; var abs = Math.abs; for (var i = 0; i < n; i++) { s += %s; } return s; }", op);
    return buf;
}

static int is_host_loop(const char *cs) {
    return !strncmp(cs, "n2j", 3) || !strncmp(cs, "site", 4) || !strcmp(cs, "prop_site");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: qjs-boundary-bench <case> [N] | --list\n"); return 1; }
    const char *cs = argv[1];
    if (!strcmp(cs, "--list")) {
        for (size_t i = 0; i < sizeof(case_names) / sizeof(case_names[0]); i++) printf("%s\n", case_names[i]);
        return 0;
    }
    int n = argc > 2 ? atoi(argv[2]) : 20000000;
    char buf[512];
    const char *src;
    if (!strcmp(cs, "ctrl")) src = loop("i", buf);
    else if (!strcmp(cs, "builtin")) src = loop("abs(i)", buf);
    else if (!strcmp(cs, "host2") || !strcmp(cs, "leaf2")) src = loop("host_add(i, 1)", buf);
    else if (!strcmp(cs, "host0")) src = loop("(host_noop(), i)", buf);
    else if (!strcmp(cs, "leaf_state")) src = loop("host_tick(i)", buf);
    else if (!strcmp(cs, "method_typed")) src = loop("world.step(i)", buf);
    else if (!strcmp(cs, "method_managed")) src = loop("world.query(i)", buf);
    else if (!strcmp(cs, "getter_native") || !strcmp(cs, "getter_typed")) src = loop("world.time", buf);
    else if (!strcmp(cs, "n2j1") || !strcmp(cs, "site1")) src = "function cb(x) { return x + 1; }";
    else if (!strcmp(cs, "n2j0") || !strcmp(cs, "site0")) src = "function cb() {}";
    else if (!strcmp(cs, "prop_site")) src = "var obj = { x: 1, y: 2, field: 3 };";
    else { fprintf(stderr, "unsupported case %s\n", cs); return 2; }

    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    HostState host_state = { 0, 1 };
    JS_SetRuntimeOpaque(rt, &host_state);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "host_add", JS_NewCFunction(ctx, host_add, "host_add", 2));
    JS_SetPropertyStr(ctx, global, "host_noop", JS_NewCFunction(ctx, host_noop, "host_noop", 0));
    JS_SetPropertyStr(ctx, global, "host_tick", JS_NewCFunctionData(ctx, host_tick, 1, 0, 0, NULL));
    {
        JS_NewClassID(&world_class_id);
        JS_NewClass(rt, world_class_id, &world_class);
        JSValue proto = JS_NewObject(ctx);
        JS_SetPropertyFunctionList(ctx, proto, world_proto_funcs, sizeof(world_proto_funcs) / sizeof(world_proto_funcs[0]));
        JS_SetClassProto(ctx, world_class_id, proto);
        JSValue world = JS_NewObjectClass(ctx, world_class_id);
        World *w = calloc(1, sizeof(World));
        w->stride = 1;
        w->time_ms = 1;
        JS_SetOpaque(world, w);
        JS_SetPropertyStr(ctx, global, "world", world);
    }

    JSValue r = JS_Eval(ctx, src, strlen(src), "<boundary>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) { fprintf(stderr, "eval threw\n"); return 1; }
    JS_FreeValue(ctx, r);
    if (is_host_loop(cs)) {
        long long s = 0;
        if (!strcmp(cs, "prop_site")) {
            JSValue obj = JS_GetPropertyStr(ctx, global, "obj");
            for (int i = 0; i < n; i++) {
                JSValue v = JS_GetPropertyStr(ctx, obj, "field");
                int32_t x; JS_ToInt32(ctx, &x, v); JS_FreeValue(ctx, v);
                s += x;
            }
            JS_FreeValue(ctx, obj);
        } else {
            JSValue cb = JS_GetPropertyStr(ctx, global, "cb");
            if (!strcmp(cs, "n2j1") || !strcmp(cs, "site1")) {
                for (int i = 0; i < n; i++) {
                    JSValue a = JS_NewInt32(ctx, i);
                    JSValue v = JS_Call(ctx, cb, JS_UNDEFINED, 1, &a);
                    int32_t x; JS_ToInt32(ctx, &x, v); JS_FreeValue(ctx, v);
                    s += x;
                }
            } else {
                for (int i = 0; i < n; i++) {
                    JSValue v = JS_Call(ctx, cb, JS_UNDEFINED, 0, NULL);
                    if (JS_IsException(v)) { fprintf(stderr, "cb threw\n"); return 1; }
                    JS_FreeValue(ctx, v);
                    s += i;
                }
            }
            JS_FreeValue(ctx, cb);
        }
        printf("%lld\n", s);
    } else {
        JSValue mainf = JS_GetPropertyStr(ctx, global, "main");
        JSValue a = JS_NewInt32(ctx, n);
        JSValue v = JS_Call(ctx, mainf, JS_UNDEFINED, 1, &a);
        if (JS_IsException(v)) { fprintf(stderr, "main threw\n"); return 1; }
        double d; JS_ToFloat64(ctx, &d, v);
        printf("%lld\n", (long long)d);
        JS_FreeValue(ctx, v); JS_FreeValue(ctx, mainf);
    }
    JS_FreeValue(ctx, global);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return 0;
}
