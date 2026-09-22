# R04：Runtime 完成事件初始化复现

日期：2026-09-21。基线 HEAD：`14baded420b35168ba31dcee1017dd10d1dfea8e`。
所属讨论：[Runtime Review R04](../history.md#r04逐字段初始化没有应用结构体默认值)。

状态：这是修复前的证据。L1 已在 `initWithAccount` 写入 `host_completion_event = .unset` 和空的 `gc_mark_footprint`。L3 又删除了公开 `init`。下面的「应失败」只描述该基线，不表示当前引擎仍有这个缺陷。现行结论在 [runtime-target-design.md](../../runtime-target-design.md) 的 L1。

本目录是隔离诊断材料，不修改 `src/` 或正式 `tests/`，也不自动加入测试门禁。
当时的测试直接导入引擎并调用其 init/create/wait 接口，没有替换引擎逻辑。
前两项为回归断言，在上述缺陷基线上应失败；第三项是显式 reset 的通过对照。

## 复现命令

从仓库根目录执行，使用 Zig 0.16.0。测试为 Debug、LLVM、链接 libc；
build-options.zig 与普通非审计配置一致，并关闭统一测试全集的导入。

```sh
mkdir -p .scratch/runtime-init-review
zig test -fllvm -lc \
  --dep zjs -Mroot=docs/runtime-review/probes/init-event.zig \
  --dep build_options -Mzjs=src/root.zig \
  -Mbuild_options=docs/runtime-review/probes/build-options.zig \
  --test-filter runtime-init-review \
  -femit-bin=.scratch/runtime-init-review/init-event-probe \
  --test-no-exec
.scratch/runtime-init-review/init-event-probe --seed=0
```

只把可重建的二进制放进 `.scratch/`；探针、命令和证据保存在 `docs/`。

## 结果与解释边界

[基线输出](init-event-baseline.txt)：`1 passed; 0 skipped; 2 failed.`，退出码 1。

- init 未把预置的 `.is_set` 改成 `.unset`。
- create 使用预置旧事件值的 allocator 存储后，无通知的到期等待错误返回 true。
  地址断言确认 Runtime 的确落在预置存储上，不是测试了未使用的缓冲区。
- 调用已有 resetHostCompletionSignal 后，同样的无通知到期等待正常返回 false。

预置的是合法旧值，用来模拟可复用存储，不依赖随机未初始化字节。
FixedBufferAllocator 只用于确定 Runtime 本体的分配地址；此诊断不是 allocator 性能比较。
对照使用的是当时已有的 reset API。这次探针本身没有改引擎；后续修复在 L1。

Atomics 的宿主等待路径本身有 reset；本次未执行 JS 层跨线程 Atomics.waitAsync 复现。
不把结果扩大为生产死锁、丢通知或性能回归。修复正式落地时应按现行验证政策运行相关检查，
本探针不代替正式回归测试和批门禁。
