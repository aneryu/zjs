# Cut A checkpoint: ACCEPT-WITH-EXCEPTION (2026-07-31)

Cut A (`e060af64`, FlowTailSummary) is **accepted** with two recorded
exceptions, per the review ruling's closure protocol.

## Exceptions

1. **Contract deviation, measured justification** — `EmissionSnapshot` does
   not carry the summary; `rollbackEmission` invalidates instead of
   restoring. The per-emission ~36-byte snapshot copy measured ~0.8% of all
   compile instructions while rollback measured zero executions on the
   corpus (OOM-abort path). Exactness preserved via rebuild-on-next-query.
2. **Structural residual, accepted** — `for(;;update)` detach/splice
   invalidates ≈37×/compile; `flowSummary` retains 0.73% of compile cycles.
   Precise tracking across the detach window would overcount tagged/watermark
   into mid-window queries; the Debug oracle rejects that design.

## Formal verdict (recorded in cut-a.md)

Two cold builds per side, all four combinations, 8 ABBA pairs: instructions
−0.123% (stable to 1e-5), cycles −2.0..−2.3%, all b-better. Zoo code-load
new-vs-old 12-sample A/B: 14444 → 14802 (+2.48%). Gates: test262 0/49775,
unit 2044/2044, test-oom 20/20, Debug oracle clean.

## Post-A full zoo (this artifact directory, `zoo-compare-post-a.json`)

**code-load 0.438 → 0.454** (B1+A compound, matching the predicted ~0.45);
throughput geomean 0.6947 → **0.6990**; regexp 1.131 (inside the noise band
adjudicated earlier: true level ≈1.11); all other benches within noise.
SplayLatency 0.629, MandreelLatency 0.867.

Provenance note (recorded honestly): the artifact's zjs binary is sha256
`841188ee…` — the cold "A-b2" build of `e060af64` from the four-combination
protocol (see cut-a.md). The artifact's repo-state fields were captured at
write time, by which the working tree already carried in-flight D0
(stabilization) edits and the user's `6d8fd0a0` docs commit; the binary
SHA-256 is the authoritative identity, and it maps to `e060af64` content.

## Campaign position

Next per the revised ruling: D0 (opcode-profiling functional repair) → D1
(symbol-root dead-protocol removal) → D2 (proven-dead facades) → fresh
pre-C1 baseline → C1 (compact Phase3Record, designed for later p3_topo/C2a
takeover) → re-instrument and pick max(p3_topo, C2a-traversal, p2_write,
p2_bind). C3 (make_ref, measured 0.12%) demoted to backlog.
