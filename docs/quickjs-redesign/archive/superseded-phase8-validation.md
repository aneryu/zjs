# Superseded Phase 8 Validation Notes

These records were removed from active `TRACKING.md` because later Phase 8 and
Phase 9 gates superseded them. They remain here for audit history only.

## Fixture Path Correction

Phase 8 validation rows that cite `tests/runner-fixtures/*` paths are historical
handoff evidence only. Those fixture files are not present in this checkout, so
the rows are superseded as current reproducible evidence by the recorded
unit/tool gates and the full local `run-test262` gate.

## Superseded Fixture Rows

| Date | Phase | Command | Exit | Notes |
|---|---|---|---|---|
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -f tests/runner-fixtures/module-with-module-flag.js` | 0 | Module metadata fixture executed as expected in the historical checkout. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -e tests/runner-fixtures/known-errors.txt -f tests/runner-fixtures/known-fail-stackunderflow.js` | 0 | Known-error loader classified expected runtime failure as known. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -v -f tests/runner-fixtures/known-fail-stackunderflow.js` | 1 | Verbose output showed the failing fixture path and stderr summary. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -m -f tests/runner-fixtures/module-with-module-flag.js` | 0 | Module option path executed with module metadata fixture as expected. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -e tests/runner-fixtures/known-errors-fixed.txt -f tests/runner-fixtures/pass.js` | 1 | Known-error fixed-path classification reported `fixed 1`. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -e tests/runner-fixtures/known-errors-negative.txt -f tests/runner-fixtures/negative-runtime-referenceerror.js` | 0 | Negative metadata runtime/type match path validated as known. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -f tests/runner-fixtures/negative-runtime-type-mismatch.js` | 1 | Wrong-type negative metadata mismatch was rejected as unexpected failure. |
| 2026-04-26 | 8 | `tmp=$(mktemp /tmp/zjs-known-errors-XXXX.txt); printf 'tests/runner-fixtures/pass.js\\n' > "$tmp"; ./zig-out/bin/run-test262 -u -e "$tmp" -f tests/runner-fixtures/known-fail-stackunderflow.js; cat "$tmp"; rm -f "$tmp"` | 1 | Known-error update mode rewrote the historical fixture list. |
| 2026-04-26 | 8 | `./zig-out/bin/run-test262 -c tests/runner-fixtures/exclude.conf -f tests/runner-fixtures/known-fail-stackunderflow.js` | 0 | Exclude configuration filtered the selected historical failure before execution. |

## Superseded Known Failures

| Date | Phase | Command | Exit | Classification | Notes |
|---|---|---|---|---|---|
| 2026-04-24 | bootstrap | `zig build test-quickjs-port --summary all` | 1 | expected_bootstrap_gap | Failed before implementation because `src/tests/quickjs_port.zig` was missing; fixed by Phase 1 bootstrap. |
| 2026-04-24 | 8 | `zig build smoke --summary all` | 1 | expected_phase8_gap | Smoke runner was real, but engine behavior had not caught up yet. Superseded by current 45/45 smoke gate. |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 5` | 1 | expected_phase8_gap | Earlier selection-only checkpoint; superseded by later `zjs` execution wiring and passing test262 gates. |
| 2026-04-24 | 8 | `./zig-out/bin/run-test262 -v -c quickjs/test262.conf -d quickjs/test262/test/built-ins/JSON 0 2` | 1 | expected_phase8_gap | Superseded by later passing JSON slices after baseline harness and template scanning repair. |
