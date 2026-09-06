/* QuickJS twin of zjs_boundary_bench.zig: same cases, JS_NewCFunction / JS_Call. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

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

static const char *loop(const char *op, char *buf) {
    sprintf(buf, "function main(n) { var s = 0; var abs = Math.abs; for (var i = 0; i < n; i++) { s += %s; } return s; }", op);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: qjs-boundary-bench <case> [N]\n"); return 1; }
    const char *cs = argv[1];
    int n = argc > 2 ? atoi(argv[2]) : 20000000;
    JSRuntime *rt = JS_NewRuntime();
    JSContext *ctx = JS_NewContext(rt);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "host_add", JS_NewCFunction(ctx, host_add, "host_add", 2));
    JS_SetPropertyStr(ctx, global, "host_noop", JS_NewCFunction(ctx, host_noop, "host_noop", 0));
    char buf[512];
    const char *src;
    if (!strcmp(cs, "ctrl")) src = loop("i", buf);
    else if (!strcmp(cs, "builtin")) src = loop("abs(i)", buf);
    else if (!strcmp(cs, "host2")) src = loop("host_add(i, 1)", buf);
    else if (!strcmp(cs, "host0")) src = loop("(host_noop(), i)", buf);
    else if (!strcmp(cs, "n2j1")) src = "function cb(x) { return x + 1; }";
    else if (!strcmp(cs, "n2j0")) src = "function cb() {}";
    else { fprintf(stderr, "unknown case %s\n", cs); return 1; }
    JSValue r = JS_Eval(ctx, src, strlen(src), "<boundary>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(r)) { fprintf(stderr, "eval threw\n"); return 1; }
    JS_FreeValue(ctx, r);
    if (!strncmp(cs, "n2j", 3)) {
        JSValue cb = JS_GetPropertyStr(ctx, global, "cb");
        long long s = 0;
        if (!strcmp(cs, "n2j1")) {
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
        printf("%lld\n", s);
        JS_FreeValue(ctx, cb);
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
