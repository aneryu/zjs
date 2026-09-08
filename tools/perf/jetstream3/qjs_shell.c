/* JetStream host adapter: global script evaluation and real QuickJS contexts. */
#include "quickjs.h"
#include "quickjs-libc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static JSContext *shell_context;

/* quickjs-libc's void event loop only logs a failed job. Keep its scheduling,
 * but make an uncaught job exception fail this benchmark process. The linker
 * wraps only references from the host library; successful engine jobs are
 * returned unchanged. Exceptions belong to the runtime, including child realms.
 */
extern int __real_JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx);
int __wrap_JS_ExecutePendingJob(JSRuntime *rt, JSContext **pctx) {
    int result = __real_JS_ExecutePendingJob(rt, pctx);
    if (result < 0) {
        js_std_dump_error(shell_context);
        exit(1);
    }
    return result;
}

static int install(JSContext *ctx, int argc, char **argv);
static JSValue eval_source(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    if (!argc || !JS_IsString(argv[0])) return JS_ThrowTypeError(ctx, "source must be a string");
    size_t n;
    const char *text = JS_ToCStringLen(ctx, &n, argv[0]);
    if (!text) return JS_EXCEPTION;
    JSValue result = JS_Eval(ctx, text, n, "<loadString>", JS_EVAL_TYPE_GLOBAL);
    JS_FreeCString(ctx, text);
    return result;
}
static JSValue read_file(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    if (!argc || !JS_IsString(argv[0])) return JS_ThrowTypeError(ctx, "path must be a string");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    size_t n;
    uint8_t *bytes = js_load_file(ctx, &n, path);
    JS_FreeCString(ctx, path);
    if (!bytes) return JS_ThrowInternalError(ctx, "cannot read file");
    int binary = 0;
    if (argc > 1 && !JS_IsUndefined(argv[1])) {
        const char *mode = JS_ToCString(ctx, argv[1]);
        if (!mode) { js_free(ctx, bytes); return JS_EXCEPTION; }
        binary = !strcmp(mode, "binary");
        JS_FreeCString(ctx, mode);
        if (!binary) { js_free(ctx, bytes); return JS_ThrowTypeError(ctx, "read mode must be binary or omitted"); }
    }
    JSValue result = binary ? JS_NewArrayBufferCopy(ctx, bytes, n) : JS_NewStringLen(ctx, (const char *)bytes, n);
    js_free(ctx, bytes);
    return result;
}
static JSValue load_file(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    if (!argc || !JS_IsString(argv[0])) return JS_ThrowTypeError(ctx, "path must be a string");
    const char *path = JS_ToCString(ctx, argv[0]);
    if (!path) return JS_EXCEPTION;
    size_t n;
    uint8_t *bytes = js_load_file(ctx, &n, path);
    if (!bytes) { JS_FreeCString(ctx, path); return JS_ThrowInternalError(ctx, "cannot read file"); }
    JSValue result = JS_Eval(ctx, (char *)bytes, n, path, JS_EVAL_TYPE_GLOBAL);
    js_free(ctx, bytes);
    JS_FreeCString(ctx, path);
    return result;
}
static JSValue run_string(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)self;
    JSContext *child = JS_NewContext(JS_GetRuntime(ctx));
    if (!child) return JS_ThrowOutOfMemory(ctx);
    if (install(child, 0, NULL) < 0) {
        JSValue error = JS_GetException(child);
        JS_FreeContext(child);
        return JS_Throw(ctx, error);
    }
    JSValue result = eval_source(child, JS_UNDEFINED, argc, argv);
    if (JS_IsException(result)) {
        JSValue error = JS_GetException(child);
        JS_FreeContext(child);
        return JS_Throw(ctx, error);
    }
    JS_FreeValue(child, result);
    JSValue global = JS_GetGlobalObject(child);
    /* Native functions retain their creating context, like QuickJS host realms. */
    JS_FreeContext(child);
    return global;
}
static int install(JSContext *ctx, int argc, char **argv) {
    js_std_add_helpers(ctx, argc, argv);
    JSValue g = JS_GetGlobalObject(ctx);
    struct { const char *name; JSCFunction *fn; } entries[] = {
        {"load",load_file},{"loadString",eval_source},{"runString",run_string},{"read",read_file},{"readFile",read_file}
    };
    for (size_t i=0;i<sizeof(entries)/sizeof(entries[0]);i++) {
        if (JS_SetPropertyStr(ctx,g,entries[i].name,JS_NewCFunction(ctx,entries[i].fn,entries[i].name,1))<0) {
            JS_FreeValue(ctx,g); return -1;
        }
    }
    JS_FreeValue(ctx,g);
    if (!js_init_module_os(ctx,"os")) return -1;
    const char *bootstrap =
        "import * as os from 'os';"
        "globalThis.arguments=scriptArgs;globalThis.printErr=print;"
        "const apply=Reflect.apply;"
        "globalThis.setTimeout=function(f,d,...a){if(typeof f!=='function')throw TypeError('callback');"
        "return os.setTimeout(()=>{try{apply(f,globalThis,a)}catch(e){Promise.reject(e)}},d);};"
        "globalThis.clearTimeout=os.clearTimeout;"
        "globalThis.setInterval=function(f,d,...a){if(typeof f!=='function')throw TypeError('callback');"
        "const t={cancelled:false};"
        "function tick(){if(t.cancelled)return;try{apply(f,globalThis,a)}catch(e){Promise.reject(e)}"
        "if(!t.cancelled)t.handle=os.setTimeout(tick,d);}t.handle=os.setTimeout(tick,d);return t;};"
        "globalThis.clearInterval=function(t){t.cancelled=true;os.clearTimeout(t.handle);};";
    JSValue result=JS_Eval(ctx,bootstrap,strlen(bootstrap),"<shell-host>",JS_EVAL_TYPE_MODULE);
    if (JS_IsException(result)) return -1;
    JS_FreeValue(ctx,result);
    return 0;
}
int main(int argc,char **argv) {
    if(argc<2) { fprintf(stderr,"usage: qjs-jetstream script.js [arguments]\n"); return 2; }
    JSRuntime *rt=JS_NewRuntime();
    if(!rt) return 1;
    js_std_init_handlers(rt);
    JS_SetHostPromiseRejectionTracker(rt,js_std_promise_rejection_tracker,NULL);
    JS_SetModuleLoaderFunc2(rt,NULL,js_module_loader,js_module_check_attributes,NULL);
    JSContext *ctx=JS_NewContext(rt);
    if(!ctx) return 1;
    shell_context=ctx;
    if(install(ctx,argc-2,argv+2)<0) { js_std_dump_error(ctx); return 1; }
    size_t n; uint8_t *bytes=js_load_file(ctx,&n,argv[1]);
    if(!bytes) { fprintf(stderr,"cannot read %s\n",argv[1]); return 1; }
    JSValue result=JS_Eval(ctx,(char*)bytes,n,argv[1],JS_EVAL_TYPE_GLOBAL);
    js_free(ctx,bytes);
    if(JS_IsException(result)) { js_std_dump_error(ctx); return 1; }
    JS_FreeValue(ctx,result);
    js_std_loop(ctx);
    return 0; /* Process teardown, matching the zjs shell's normal mode. */
}
