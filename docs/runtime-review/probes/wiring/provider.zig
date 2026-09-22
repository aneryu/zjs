const engine = @import("engine");
const hooks: engine.core.Hooks = .{ .invoke = engine.exec.invoke };
pub fn get() *const engine.core.Hooks {
    return &hooks;
}
