#!/usr/bin/env bash
# FINAL SWITCH -- the standing rules, fault-injected.
#
# Gate A surfaced five process defects. Each one produced a wrong or vacuous
# result on a real run, so each is encoded as a machine-enforced rule rather
# than as advice, and this file is the regression test for the rules
# themselves. It is cheap (seconds, no heavy build) so there is no excuse for
# not running it, and `zig build final-switch-selftest` wires it into the build
# graph so it is discoverable without reading this directory first.
#
# Every rule is checked in both directions where that is possible: the correct
# form must PASS, and a deliberately reintroduced defect must FAIL. A rule that
# has only ever been observed passing is a comment.
#
#   RULE A  AFFINITY     the orchestrator SETS `taskset -c $FS_CPU` and verifies
#                        it INDEPENDENTLY; a runner's self-report is corroborated,
#                        never trusted on its own.
#   RULE B  TS PROBES    TypeScript probes route through
#                        parseAndCompileV2TestProgram(); `zjs -e '<ts>'` is banned
#                        because it answers SyntaxError for every construct.
#   RULE C  L3 COLLECT   `v2_construct_emitted > 0` is asserted BEFORE
#                        `legacy_in_v2_unallowed == 0` is believed.
#   RULE D  CORPUS SKIPS the actual skipped set is compared against an EXPLICIT
#                        per-case allowlist, by identity. No proportional tolerance.
#   RULE E  STRICT SHELL scripts are shellcheck-clean, and abort LOUDLY rather
#                        than silently emitting nothing.
#
# Usage: tools/final-switch/selftest.sh [--zjs PATH] [--no-engine]
#   --zjs PATH   engine binary for the RULE B dynamic check (default zig-out/bin/zjs)
#   --no-engine  skip only the checks that need a built binary, and SAY SO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=./preflight.sh
source "$HERE/preflight.sh"
fs_strict "selftest.sh"

ZJS="$REPO/zig-out/bin/zjs"
WITH_ENGINE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --zjs) ZJS="$2"; shift 2 ;;
        --no-engine) WITH_ENGINE=0; shift ;;
        *) fs_die "unknown argument: $1" ;;
    esac
done

cd "$REPO" || fs_die "cannot enter $REPO"

# This file runs NO build and NO measurement. Its single fs_pinned call is a
# `true`, present to exercise the pin verification path, so it must not contend
# for the exclusive host lock -- and, more importantly, must not DEADLOCK when
# invoked from inside a context that already holds it, which
# `flock -x /tmp/zjs-host-heavy.lock zig build final-switch-selftest` is.
# flock is not reentrant across processes, and a nested acquisition hangs with
# no output at all, which is exactly the silent-death shape RULE E exists for.
export FS_LOCK_ALREADY_HELD=1

TMP="$(mktemp -d -t fs-selftest-XXXXXX)"
trap 'rm -rf "$TMP"; fs_abort_banner' EXIT

FAILED=0
CHECKS=0
SCRIPTS=("$HERE"/*.sh)

pass() { CHECKS=$((CHECKS + 1)); printf '  PASS  %-14s %s\n' "$1" "$2"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=1; printf '  FAIL  %-14s %s\n' "$1" "$2"; }

# Static rules are about CODE, not about the prose that explains the code --
# every one of these rules names the pattern it bans, in a comment, on purpose.
# So strip whole-line comments before every static scan.
code_only()    { grep -vE '^[[:space:]]*#' "$1"; }
zig_code_only() { grep -vE '^[[:space:]]*//' "$1"; }

# expect_rc <wanted> <id> <description> <cmd...>
expect_rc() {
    local want="$1" id="$2" desc="$3"; shift 3
    local rc=0 out
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then
        pass "$id" "$desc"
    else
        bad "$id" "$desc (rc=$rc, wanted $want)"
        printf '%s\n' "$out" | tail -6 | sed 's/^/          | /'
    fi
}

# expect_nonzero <id> <description> <cmd...>
expect_nonzero() {
    local id="$1" desc="$2"; shift 2
    local rc=0 out
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" != 0 ]; then
        pass "$id" "$desc"
    else
        bad "$id" "$desc (succeeded; the check has no teeth)"
        printf '%s\n' "$out" | tail -6 | sed 's/^/          | /'
    fi
}

fs_say "FINAL SWITCH SELFTEST -- the Gate A process defects, as standing rules"

# ==========================================================================
# RULE A -- AFFINITY.
#
# Gate A's first zoo attempt omitted `taskset -c 19`; run_zoo_compare.py
# refused all three invocations (rc=2). It failed closed, but the orchestrator
# should never have been able to request an unpinned measurement at all, and
# the runner's own affinity report is a self-report -- one source attesting
# itself is not verification.
# ==========================================================================
fs_say "RULE A -- affinity is set by the orchestrator and verified independently"

# A1. Exactly one audited chokepoint spells `taskset`. preflight.sh is that
# chokepoint; this file is the checker and must be able to name what it bans.
offenders=""
for script in "${SCRIPTS[@]}"; do
    case "$(basename "$script")" in preflight.sh | selftest.sh) continue ;; esac
    if code_only "$script" | grep -qE '(^|[^_[:alnum:]])taskset([^_[:alnum:]]|$)'; then
        offenders="$offenders $(basename "$script")"
    fi
done
if [ -z "$offenders" ]; then
    pass A1 "only preflight.sh spells taskset (single audited chokepoint)"
else
    bad A1 "these scripts pin by hand instead of via fs_pinned:$offenders"
fi

# A2. Every affinity-ATTESTING runner is invoked through fs_pinned. The runner
# list is derived, not hardcoded, so a new attesting runner is covered the day
# it lands.
mapfile -t ATTESTING < <(grep -rl 'sched_getaffinity' "$REPO/tools/perf" 2>/dev/null | sed 's#.*/##' | sort -u)
if [ "${#ATTESTING[@]}" -eq 0 ]; then
    bad A2 "found no affinity-attesting runner under tools/perf; the derivation broke"
else
    unpinned=""
    for script in "${SCRIPTS[@]}"; do
        case "$(basename "$script")" in selftest.sh) continue ;; esac
        for runner in "${ATTESTING[@]}"; do
            while IFS= read -r line; do
                case "$line" in
                    *fs_pinned*) ;;
                    *) unpinned="$unpinned [$(basename "$script")] $line" ;;
                esac
            done < <(code_only "$script" | grep -F "$runner" || true)
        done
    done
    if [ -z "$unpinned" ]; then
        pass A2 "all ${#ATTESTING[@]} attesting runners invoked only via fs_pinned"
    else
        bad A2 "runner invoked without fs_pinned:$unpinned"
    fi
fi

# A3. The pin actually takes effect, observed from inside the pinned process,
# via /proc -- a different mechanism from the runner's os.sched_getaffinity.
ATTEST="$TMP/attest.tsv"
: > "$ATTEST"
if FS_AFFINITY_ATTEST="$ATTEST" fs_pinned true >/dev/null 2>&1 \
   && [ "$(cut -f1 "$ATTEST" | head -1)" = "$(cut -f2 "$ATTEST" | head -1)" ] \
   && [ "$(cut -f2 "$ATTEST" | head -1)" = "$FS_CPU" ]; then
    pass A3 "fs_pinned observes Cpus_allowed_list=$FS_CPU from inside the pinned process"
else
    bad A3 "fs_pinned did not attest an effective pin of [$FS_CPU]: $(cat "$ATTEST")"
fi

# A4-A7. The join arbitrates; fault-inject each way it must refuse.
python3 - "$TMP" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1]) / "perf"
out.mkdir(parents=True, exist_ok=True)
benches = ["code-load", "richards", "splay"]
def zoo(tag, ratios, cpu=19, affinity=None):
    doc = {
        "cpu": cpu,
        "effectiveAffinity": affinity if affinity is not None else [cpu],
        "samplesPerEnginePerBench": 4,
        "binaries": {"zjs": {"sha256": tag}},
        "summary": {"throughputRatios": dict(zip(benches, ratios))},
    }
    (out / f"zoo-{tag}.json").write_text(json.dumps(doc))
def micro(tag, cpu=19, affinity=None):
    doc = {
        "cpu": cpu,
        "effectiveAffinity": affinity if affinity is not None else [cpu],
        "pairedSamples": 12,
        "checksum": "same",
        "metrics": {k: {"ratioMedian": 1.0} for k in ("instructions", "cycles", "wallSeconds")},
    }
    (out / f"micro-{tag}.json").write_text(json.dumps(doc))
zoo("cand-b1", [1.30, 1.02, 1.01]); zoo("cand-b2", [1.30, 1.02, 1.01])
zoo("legacy-a1", [1.00, 1.00, 1.00]); zoo("legacy-a2", [1.00, 1.00, 1.00])
for t in ("a1b1", "a1b2", "a2b1", "a2b2"):
    micro(t)
attest = out / "affinity-attestation.tsv"
attest.write_text("".join("19\t19\trun %d\n" % i for i in range(8)))
PY
PERF="$TMP/perf"

expect_rc 0 A4 "the honest artifact set joins cleanly (so the refusals below mean something)" \
    python3 "$HERE/join_results.py" --perf "$PERF"

cp "$PERF/zoo-cand-b1.json" "$TMP/keep-b1.json"
python3 - "$PERF" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]) / "zoo-cand-b1.json"
doc = json.loads(p.read_text()); doc["effectiveAffinity"] = [0, 1, 2, 3]
p.write_text(json.dumps(doc))
PY
expect_nonzero A5 "an artifact whose effectiveAffinity is not [cpu] is REFUSED" \
    python3 "$HERE/join_results.py" --perf "$PERF"
cp "$TMP/keep-b1.json" "$PERF/zoo-cand-b1.json"

mv "$PERF/zoo-legacy-a2.json" "$TMP/held-a2.json"
expect_nonzero A6 "a MISSING artifact is refused, not averaged in as a smaller sample" \
    python3 "$HERE/join_results.py" --perf "$PERF"
mv "$TMP/held-a2.json" "$PERF/zoo-legacy-a2.json"

mv "$PERF/affinity-attestation.tsv" "$TMP/held-attest.tsv"
expect_nonzero A7 "runner self-reports alone are refused without the orchestrator's ledger" \
    python3 "$HERE/join_results.py" --perf "$PERF"
mv "$TMP/held-attest.tsv" "$PERF/affinity-attestation.tsv"

printf '19\t3\tan invocation that did not land on 19\n' >> "$PERF/affinity-attestation.tsv"
expect_nonzero A8 "an orchestrator observation that disagrees with the request is refused" \
    python3 "$HERE/join_results.py" --perf "$PERF"

# ==========================================================================
# RULE B -- TS PROBES.
#
# `zjs -e '<ts source>'` has no TypeScript handling: the `-e` path has no
# filename for the source-kind autodetect to work from, so it answers
# SyntaxError for EVERY construct. As a probe it is indistinguishable from an
# engine failure and reads as a finding. The sanctioned route is
# parseAndCompileV2TestProgram() with `.source_kind = .typescript`.
#
# The scan below is deliberately literal and has NO carve-out for prose: every
# comment in this directory that names the banned form writes it with the
# `<ts source>` placeholder, so a concrete TypeScript keyword after a `-e`
# anywhere under tools/ or docs/ is always a real occurrence.
# ==========================================================================
fs_say "RULE B -- TypeScript probes route through parseAndCompileV2TestProgram()"

# B1. No `zjs -e '<typescript>'` formulation anywhere in the tooling or docs.
# Matches `-e` as a word followed on the same line by a TypeScript-only
# keyword. Prose that names the banned FORM (`zjs -e '<ts source>'`) carries no
# such keyword and so does not match.
#
# A plain recursive grep, not `git grep`: an untracked scratch script is
# exactly where this formulation gets written, and git grep would not see it.
TS_KEYWORDS='enum |interface |namespace |declare |satisfies |implements |abstract class'
offending="$(grep -rnE "(^|[[:space:]])-e[[:space:]].*($TS_KEYWORDS)" \
    "$REPO/tools" "$REPO/docs" 2>/dev/null || true)"
if [ -z "$offending" ]; then
    pass B1 "no 'zjs -e <typescript>' probe in tools/ or docs/"
else
    bad B1 "a TypeScript probe is expressed as 'zjs -e', which cannot work:"
    printf '%s\n' "$offending" | sed 's/^/          | /'
fi

# B3. The sanctioned route is pinned by a named Zig test, which `zig build
# test` runs. Static here so a rename is caught even without a build.
if grep -q 'RULE B -- TypeScript probes route through parseAndCompileV2TestProgram' \
        "$REPO/src/compiler_v2/tests.zig"; then
    pass B3 "the sanctioned route is pinned by a named test in src/compiler_v2/tests.zig"
else
    bad B3 "src/compiler_v2/tests.zig no longer pins the parseAndCompileV2TestProgram route"
fi

# B5. The TypeScript L3 workload reaches the compiler as a FILE (the engine
# strips by path), and migration_gates.sh checks the workload's exit status --
# otherwise a TypeScript workload that SyntaxErrors would look like a collect
# that merely emitted nothing, which is the same false negative in a new place.
if [ -f "$HERE/l3_workload.ts" ] && grep -q 'run_rc' "$HERE/migration_gates.sh"; then
    pass B5 "the .ts workload is a file, and its exit status is checked, not just its report"
else
    bad B5 "migration_gates.sh no longer checks the workload's exit status (or l3_workload.ts is gone)"
fi

if [ "$WITH_ENGINE" = 1 ]; then
    if [ ! -x "$ZJS" ]; then
        bad B2 "engine binary not found at $ZJS -- run 'zig build zjs', or pass --no-engine and say so"
    else
        # B2. Ground the ban in observed behaviour. Built from a variable so
        # this file does not itself contain the pattern B1 bans.
        ts_source='enum Direction { Up, Down }'
        eval_out="$("$ZJS" -e "$ts_source" 2>&1)" && eval_rc=0 || eval_rc=$?
        case "$eval_out" in
            *SyntaxError*)
                pass B2 "'-e' on TypeScript reports SyntaxError (rc=$eval_rc) -- a false negative, as claimed" ;;
            *)
                bad B2 "'-e' on TypeScript no longer reports SyntaxError (rc=$eval_rc): $eval_out"
                printf '          the ban was derived from this behaviour; re-derive it before relaxing\n' ;;
        esac
        # B4. The same source through the sanctioned file route DOES compile,
        # so B2 is a property of the probe formulation, not of the construct.
        printf '%s\nglobalThis.ok = Direction.Down;\n' "$ts_source" > "$TMP/probe.ts"
        if "$ZJS" "$TMP/probe.ts" >/dev/null 2>&1; then
            pass B4 "the same construct compiles when the source kind is known -- the probe was the fault"
        else
            bad B4 "the sanctioned route also failed; the TypeScript pipeline itself is broken"
        fi
    fi
else
    printf '  SKIP  B2/B4          --no-engine: the dynamic half of RULE B did NOT run\n'
fi

# ==========================================================================
# RULE C -- L3 COLLECT.
#
# Gate A's first collect invoked the binary with --print-config-signature,
# which compiles nothing, and produced `v2_construct_emitted=0 ...
# legacy_in_v2_unallowed=0` -- a vacuous zero that reads exactly like a pass.
# ==========================================================================
fs_say "RULE C -- emitted>0 is asserted BEFORE unallowed==0 is believed"

# C1. The historical defect, verbatim: the exact line the vacuous run printed.
VACUOUS='QCP-1 L3 emission coverage: v2_construct_emitted=0 legacy_construct_emitted=0 legacy_in_v2_scope=0 legacy_in_v2_unallowed=0 sites_dropped=0'
REAL='QCP-1 L3 emission coverage: v2_construct_emitted=387 legacy_construct_emitted=0 legacy_in_v2_scope=0 legacy_in_v2_unallowed=0 sites_dropped=0'
DIRTY='QCP-1 L3 emission coverage: v2_construct_emitted=387 legacy_construct_emitted=4 legacy_in_v2_scope=4 legacy_in_v2_unallowed=4 sites_dropped=0'

verdict="$(fs_l3_verdict "$VACUOUS")" && vrc=0 || vrc=$?
case "$verdict:$vrc" in
    VACUOUS*:1) pass C1 "the historical vacuous report is reported VACUOUS, not PASS" ;;
    *)          bad  C1 "vacuous report gave '$verdict' rc=$vrc; the defect would land again" ;;
esac

verdict="$(fs_l3_verdict "$REAL")" && vrc=0 || vrc=$?
case "$verdict:$vrc" in
    PASS*:0) pass C2 "a real collect (emitted=387, unallowed=0) passes" ;;
    *)       bad  C2 "a real collect was rejected: '$verdict' rc=$vrc" ;;
esac

verdict="$(fs_l3_verdict "$DIRTY")" && vrc=0 || vrc=$?
case "$verdict:$vrc" in
    FAIL*:1) pass C3 "unallowed>0 over emitted>0 fails" ;;
    *)       bad  C3 "unallowed=4 was not rejected: '$verdict' rc=$vrc" ;;
esac

verdict="$(fs_l3_verdict "")" && vrc=0 || vrc=$?
case "$verdict:$vrc" in
    NOREPORT*:1) pass C4 "no coverage line at all fails (a silent collect is not a pass)" ;;
    *)           bad  C4 "an absent report gave '$verdict' rc=$vrc" ;;
esac

# C5. One implementation. An open-coded comparison in the gate could be right
# here and wrong there.
if grep -q 'fs_l3_verdict' "$HERE/migration_gates.sh" \
   && ! grep -qE 'v2_construct_emitted=\[0-9\]\+.*cut -d= -f2' "$HERE/migration_gates.sh"; then
    pass C5 "migration_gates.sh routes through fs_l3_verdict rather than open-coding it"
else
    bad C5 "migration_gates.sh open-codes the emission assertion; it can drift from this test"
fi

# ==========================================================================
# RULE D -- CORPUS SKIPS.
#
# The corpus asserted `skipped * 2 <= cases.len`: up to HALF of it could stop
# covering anything while the test stayed green. The replacement is an explicit
# per-case allowlist compared by identity, in both directions.
# ==========================================================================
fs_say "RULE D -- the skipped set is compared against an explicit allowlist"

CORPUS="$REPO/src/compiler_v2/tests.zig"

if zig_code_only "$CORPUS" | grep -qE 'skipped[[:space:]]*\*[[:space:]]*[0-9]+[[:space:]]*<=|skipped[[:space:]]*<=[[:space:]]*cases\.len[[:space:]]*/'; then
    bad D1 "a PROPORTIONAL skip tolerance is back in the corpus"
else
    pass D1 "no proportional skip tolerance in the corpus"
fi

# Defined AND called: a comparison helper that nothing invokes is a comment.
if grep -q 'fn expectCoverageSkipSetMatches' "$CORPUS" \
   && grep -q 'try expectCoverageSkipSetMatches(&cases, &skipped' "$CORPUS" \
   && grep -q 'expect_skip' "$CORPUS"; then
    pass D2 "the corpus calls the identity comparison over its own skipped set"
else
    bad D2 "the corpus no longer calls expectCoverageSkipSetMatches over its skipped set"
fi

# D3. Count allowlist entries INSIDE the corpus array only -- not in prose, not
# in the synthetic cases the RULE D self-test builds.
corpus_body="$TMP/corpus-cases.zig"
awk '/^    const cases = \[_\]Case\{$/{inside=1;next} inside&&/^    \};$/{exit} inside' \
    "$CORPUS" > "$corpus_body"
if [ ! -s "$corpus_body" ]; then
    bad D3 "could not locate the coverage corpus array; the D3 extraction broke"
else
    allowlisted="$(grep -c '\.expect_skip = true' "$corpus_body" || true)"
    if [ "$allowlisted" = "1" ] && grep -q '\.source = "new\.target;"' "$corpus_body"; then
        pass D3 "exactly one allowlisted corpus skip, and it is the top-level 'new.target;'"
    else
        bad D3 "expected exactly 1 corpus allowlist entry (top-level 'new.target;'), found $allowlisted"
        grep -n '\.expect_skip = true' "$corpus_body" | sed 's/^/          | /'
    fi
fi

if grep -q 'RULE D -- the skip allowlist is compared by identity' "$CORPUS"; then
    pass D4 "the identity comparison is itself fault-injected by a Zig self-test"
else
    bad D4 "the RULE D Zig self-test is gone; the comparison can rot silently"
fi

# ==========================================================================
# RULE E -- STRICT SHELL.
#
# A `set -u` unbound-variable bug killed two separate Gate A measurement
# scripts. Each time the script died mid-run, printed one line of bash
# diagnostic among hundreds, and produced no verdict -- which reads like a run
# still in progress, not like a run that died.
# ==========================================================================
fs_say "RULE E -- strict shell, shellcheck-clean, and a LOUD abort"

# E1. Syntax, always, with no external dependency.
syntax_bad=""
for script in "${SCRIPTS[@]}"; do
    bash -n "$script" 2>/dev/null || syntax_bad="$syntax_bad $(basename "$script")"
done
if [ -z "$syntax_bad" ]; then
    pass E1 "all ${#SCRIPTS[@]} scripts parse under bash -n"
else
    bad E1 "syntax errors in:$syntax_bad"
fi

# E2. Strict mode and the completion trap, via the single helper. A script that
# sets its own `set -u` without fs_strict has no abort banner.
missing=""
for script in "${SCRIPTS[@]}"; do
    name="$(basename "$script")"
    case "$name" in preflight.sh) continue ;; esac
    grep -q '^fs_strict ' "$script" || missing="$missing $name(no-fs_strict)"
    grep -q 'fs_finish' "$script"   || missing="$missing $name(no-fs_finish)"
    if grep -qE '^set -' "$script"; then
        missing="$missing $name(open-codes set -u instead of fs_strict)"
    fi
    # Only this file may declare the host lock already held. An orchestration
    # script that did so would run builds and measurements unlocked -- and a
    # deadlock on a non-reentrant flock is itself a silent death.
    case "$name" in selftest.sh) ;; *)
        if grep -q 'FS_LOCK_ALREADY_HELD=1' "$script"; then
            missing="$missing $name(declares the host lock already held)"
        fi ;;
    esac
done
if [ -z "$missing" ]; then
    pass E2 "every script enters strict mode via fs_strict and exits via fs_finish"
else
    bad E2 "strict-mode wiring missing:$missing"
fi

# E3. THE REGRESSION TEST. Inject a genuine unbound-variable fault and require
# a loud abort and a non-zero status -- not silence.
cat > "$TMP/unbound.sh" <<EOF
#!/usr/bin/env bash
source "$HERE/preflight.sh"
fs_strict "injected-unbound-variable"
printf 'work started\n'
printf '%s\n' "\$THIS_VARIABLE_IS_NOT_SET"
printf 'work finished (must never print)\n'
fs_finish 0
EOF
inj_rc=0
inj_out="$(bash "$TMP/unbound.sh" 2>&1)" || inj_rc=$?
if [ "$inj_rc" != 0 ] \
   && printf '%s' "$inj_out" | grep -q 'ABORTED injected-unbound-variable' \
   && ! printf '%s' "$inj_out" | grep -q 'work finished'; then
    pass E3 "an unbound variable aborts LOUDLY with rc=$inj_rc, not silently"
else
    bad E3 "an unbound variable did not produce a loud abort (rc=$inj_rc)"
    printf '%s\n' "$inj_out" | sed 's/^/          | /'
fi

# E4. No false positives: a clean run must not print the banner.
cat > "$TMP/clean.sh" <<EOF
#!/usr/bin/env bash
source "$HERE/preflight.sh"
fs_strict "clean-run"
printf 'verdict: fine\n'
fs_finish 0
EOF
clean_rc=0
clean_out="$(bash "$TMP/clean.sh" 2>&1)" || clean_rc=$?
if [ "$clean_rc" = 0 ] && ! printf '%s' "$clean_out" | grep -q 'ABORTED'; then
    pass E4 "a completed run exits 0 with no abort banner (no false positives)"
else
    bad E4 "a clean run reported an abort (rc=$clean_rc): $clean_out"
fi

# E5. A non-zero verdict must still be a verdict, not an abort.
cat > "$TMP/failing.sh" <<EOF
#!/usr/bin/env bash
source "$HERE/preflight.sh"
fs_strict "failing-gate"
printf 'verdict: gate failed\n'
fs_finish 1
EOF
fail_rc=0
fail_out="$(bash "$TMP/failing.sh" 2>&1)" || fail_rc=$?
if [ "$fail_rc" = 1 ] && ! printf '%s' "$fail_out" | grep -q 'ABORTED'; then
    pass E5 "a failing GATE exits 1 as a verdict, distinct from an abort"
else
    bad E5 "a failing gate was confused with an abort (rc=$fail_rc): $fail_out"
fi

# E6. shellcheck, when it exists. `bash -n` catches syntax; only shellcheck
# catches the unbound-variable class statically, which is why it is the primary
# form of this rule and the checks above are the guaranteed floor beneath it.
SHELLCHECK="${FS_SHELLCHECK:-$(command -v shellcheck 2>/dev/null || true)}"
if [ -n "$SHELLCHECK" ] && [ -x "$SHELLCHECK" ]; then
    sc_rc=0
    # -P resolves `source "$HERE/preflight.sh"` regardless of the caller's cwd.
    sc_out="$("$SHELLCHECK" -x -P "$HERE" -s bash -S style "${SCRIPTS[@]}" 2>&1)" || sc_rc=$?
    if [ "$sc_rc" = 0 ]; then
        pass E6 "shellcheck -x -S style is clean over all ${#SCRIPTS[@]} scripts"
    else
        bad E6 "shellcheck reported findings:"
        printf '%s\n' "$sc_out" | head -30 | sed 's/^/          | /'
    fi
elif [ "${FS_REQUIRE_SHELLCHECK:-0}" = 1 ]; then
    bad E6 "FS_REQUIRE_SHELLCHECK=1 but no shellcheck on PATH (set FS_SHELLCHECK)"
else
    printf '  NOTE  E6           shellcheck not installed: E1-E5 are the guard that replaces it.\n'
    printf '                     Install it, or set FS_SHELLCHECK, and re-run with\n'
    printf '                     FS_REQUIRE_SHELLCHECK=1 to make its absence a failure.\n'
fi

fs_say "SELFTEST checks=$CHECKS FAILED=$FAILED"
if [ "$FAILED" != 0 ]; then
    printf 'error: a standing rule is no longer enforced. Each one is a Gate A defect that\n' >&2
    printf '       already produced a wrong or vacuous result once; do not relax it without\n' >&2
    printf '       re-deriving why it was written.\n' >&2
fi
fs_finish "$FAILED"
