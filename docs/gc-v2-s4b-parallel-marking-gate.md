# S4b：并行标记按堆规模门控（driver 设计，2026-09-02）

状态：规格 r2（2026-09-02 23:00 修订）。r1 的「默认 64MiB」被场 B 筛查证伪：splay 的 major 起始 live 估计本就 ≥64MiB（splay 树几十 MB），门没关上（{15-19}/{19} cycles 1.080，helper 仍 3）。driver 规格错误，记账。

## 事实
- `gc_parallel_mark.zig:46` `max_workers = 3`；`:162` `want = min(max_workers, cpus-1)`，cpus 取自进程亲和集。单核记分板
  （CPU19）永远 0 helper，所以五个月没看见账。
- 2026-09-01 校准实测（infra/measure-fields）：同二进制 4 核集 vs 单核，**splay cycles(u+k) +14.6% / wall +15.2%，EB +7.2%**——
  donation+MPMC ring+原子+缓存流量在 Octane 级 live（2–10MB）上连 wall 都没赚回。V8/JSC 的并行标记只在大堆上净正。

## 设计
1. **门控而非删除，默认关闭**：helper 只在「本轮 major 开始时 live 估计 ≥ `parallel_mark_min_live_bytes`」时参与；**默认阈值 = ∞
   （`maxInt`，即并行标记默认不参与）**——本机在任何已测规模（含 splay 数十 MB live）上并行标记都是净负（+8~15%），没有证据支持任何
   有限默认阈值。`ZJS_GC_PARALLEL_MIN_LIVE_MB` 覆盖（0=永远并行，用于回归并行协议；正数=大堆实验）。机制保留，等待大堆净正证据再定阈值。
2. 门控点：`gc_trace_stw` 发起 marking job 时决定 `want`；helper 线程可以常驻但空闲（不 spawn/join 每轮），门控只影响
   `expected=count` 的发布——保持 S1 已批的 arrival/ack 握手协议不变。
3. minor 不并行（现状如此，确认不变）。
4. 测试：现有并行标记确定性交错测试用阈值 0 跑；新增「阈值门控」单测：live<阈值 → helper 参与数 0；live≥阈值 → min(3, cpus-1)。

## 验收（筛查级，场 B：CPU 15-19，5 核 → 3 helper）
- 同一候选二进制，六负载各两种亲和：`{19}` vs `{15-19}`；采 cycles(u+k，全线程)、wall、`--gc-stats` major pause p50/p95。
- 预注册：门控后 `{15-19}` 的 cycles/wall 与 `{19}` 之差 ≤ ±1%（并行不再被激活）；对照 `ZJS_GC_PARALLEL_MIN_LIVE_MB=0`
  重现 09-01 的 +7~15%（证明门控确实关掉了那笔账，而不是其他因素）。
- 单核记分板（CPU19 正式）读数应完全不变（Stage 0 自比 ≈1.000）。
- 不做多核正式 ABBA（合同禁止）；这是行为门控，不是吞吐刀。

## 边界
不改 donation/ring 协议；不动 `max_workers`；不加过渡开关（阈值本身就是终态参数）。
