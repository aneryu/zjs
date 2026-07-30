#!/usr/bin/env bun

// P7-70 analysis: turn the formal run into resolvability.json, pareto-current.json
// and pareto-current.md. Dossier-scoped, not campaign tooling: it only reads the
// artifacts produced by tools/compare/run_microbench.js and never measures.
//
// Usage:
//   bun build-pareto.js --run-a A.json --run-b B.json --build-b C.json --outdir DIR

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const argv = process.argv.slice(2);
const opts = {};
for (let i = 0; i < argv.length; i += 2) opts[argv[i].replace(/^--/, '')] = argv[i + 1];
const runA = JSON.parse(fs.readFileSync(opts['run-a'], 'utf8'));
const runB = opts['run-b'] ? JSON.parse(fs.readFileSync(opts['run-b'], 'utf8')) : null;
const buildB = opts['build-b'] ? JSON.parse(fs.readFileSync(opts['build-b'], 'utf8')) : null;
const outdir = opts.outdir ?? '.';
fs.mkdirSync(outdir, { recursive: true });

// ---------------------------------------------------------------------------
// Subsystem clustering. Keyed by case name so it is auditable; the fallback is
// the suite category, and any unmapped case is reported rather than absorbed.
// ---------------------------------------------------------------------------

const subsystemByCase = {
    // call
    func_call: 'call',
    call2_loop: 'call',
    arrow_call_loop: 'call',
    arrow_tail_recursion: 'call',
    vm_int_sum_large: 'call',
    // closure / function creation
    closure_var: 'closure/function-creation',
    closure_call_loop: 'closure/function-creation',
    // typed-array / ArrayBuffer
    typed_array_read: 'typed-array/ArrayBuffer',
    typed_array_write: 'typed-array/ArrayBuffer',
    // control, date
    empty_loop: 'control',
    date_now: 'date',
};

const subsystemByCategory = {
    object: 'binding/property',
    global: 'binding/property',
    destructuring: 'binding/property',
    collection: 'binding/property',
    array: 'array',
    sort: 'array',
    string: 'string/URI',
    uri: 'string/URI',
    json: 'string/URI',
    arithmetic: 'number/dtoa',
    conversion: 'number/dtoa',
    math: 'number/dtoa',
    bigint: 'BigInt',
    regexp: 'regexp',
    typedarray: 'typed-array/ArrayBuffer',
    function: 'call',
    control: 'control',
    date: 'date',
};

function subsystemOf(row) {
    return subsystemByCase[row.name] ?? subsystemByCategory[row.category] ?? 'unmapped';
}

// Cases whose mechanism a landed commit on this branch already touches. Used
// only to flag "already attributed" in the top-10 table; it is a claim about
// coverage, not about the size of any remaining gap.
const relatedOptimisation = {
    array_map_callback: '63c409c0 perf: reuse active Machine for array callbacks (P7-40 re-measured this case at 1.364x cycles)',
    prop_read_mono: 'P7-10 property-lookup audit; top-level binding access registered as the open question',
    global_read_loop: 'P7-10 property-lookup audit; Phase 1-6 global lexical work (1.607 -> 1.079 across snapshots)',
    proto_read: 'Phase 1-6 prototype read work (1.437 -> 1.063 across snapshots)',
    prop_read_poly3: 'Phase 1-6 inline-cache/shape work; zjs now ahead',
    regexp_test_cached: 'e8ee55b regexp lastIndex alignment; zjs ahead',
    vm_int_sum_large: 'Phase 1-6 VM loop work (1.620 -> 1.121 across snapshots)',
};

// ---------------------------------------------------------------------------

const geomean = (values) => Math.exp(values.reduce((a, v) => a + Math.log(v), 0) / values.length);
const sum = (values) => values.reduce((a, v) => a + v, 0);
const median = (values) => {
    if (values.length === 0) return null;
    const s = [...values].sort((a, b) => a - b);
    const mid = (s.length - 1) / 2;
    return s.length % 2 === 1 ? s[mid] : (s[Math.floor(mid)] + s[Math.ceil(mid)]) / 2;
};

function okCases(report) {
    return (report?.cases ?? []).filter((row) => row.status === 'ok');
}

function indexByName(report) {
    return Object.fromEntries(okCases(report).map((row) => [row.name, row]));
}

const byNameB = runB ? indexByName(runB) : {};
const byNameBuildB = buildB ? indexByName(buildB) : {};

function overlaps(a, b) {
    return a.lo <= b.hi && b.lo <= a.hi;
}

const rows = okCases(runA).map((row) => {
    const mainRatio = row.paired.median;
    const mainBand = { lo: row.paired.p25, hi: row.paired.p75 };
    const vb = byNameB[row.name] ?? null;
    const cb = byNameBuildB[row.name] ?? null;
    const validationRatio = vb ? vb.paired.median : null;
    const validationBand = vb ? { lo: vb.paired.p25, hi: vb.paired.p75 } : null;
    const directionAgrees =
        validationRatio == null ? null : Math.sign(mainRatio - 1) === Math.sign(validationRatio - 1);
    const bandOverlap = validationBand == null ? null : overlaps(mainBand, validationBand);
    const deltaMain = row.zjs.median - row.qjs.median;
    const deltaValidation = vb ? vb.zjs.median - vb.qjs.median : null;
    const withinRunStable = (row.paired.p75 - row.paired.p25) / row.paired.median <= 0.05;
    // Route eligibility needs a case that survived an independent round; a case
    // that reverses direction between rounds is never route eligible.
    const stability =
        validationRatio == null
            ? withinRunStable
                ? 'stable-within-run'
                : 'unstable-within-run'
            : directionAgrees && bandOverlap
              ? 'stable'
              : directionAgrees
                ? 'stable-direction-only'
                : 'unstable';
    return {
        name: row.name,
        category: row.category,
        subsystem: subsystemOf(row),
        resolvabilityClass: row.resolvability.resolvabilityClass,
        startupShareQjs: row.resolvability.startupShareQjs,
        startupShareZjs: row.resolvability.startupShareZjs,
        adjusted: row.resolvability.adjusted,
        qjsMedianMs: row.qjs.median,
        zjsMedianMs: row.zjs.median,
        qjsIqrMs: row.qjs.p75 - row.qjs.p25,
        zjsIqrMs: row.zjs.p75 - row.zjs.p25,
        pairedRatio: mainRatio,
        pairedP25: row.paired.p25,
        pairedP75: row.paired.p75,
        pairedGeomean: row.paired.geomean,
        absoluteDeltaMs: deltaMain,
        validation: vb
            ? {
                sampled: true,
                pairedRatio: validationRatio,
                pairedP25: vb.paired.p25,
                pairedP75: vb.paired.p75,
                absoluteDeltaMs: deltaValidation,
                directionAgrees,
                iqrOverlap: bandOverlap,
                absoluteDeltaMovementMs: deltaValidation - deltaMain,
            }
            : { sampled: false },
        buildInstanceB: cb
            ? {
                sampled: true,
                pairedRatio: cb.paired.median,
                absoluteDeltaMs: cb.zjs.median - cb.qjs.median,
            }
            : { sampled: false },
        stability,
        routeEligible: stability === 'stable' || stability === 'stable-direction-only',
        relatedOptimisation: relatedOptimisation[row.name] ?? null,
    };
});

const unmapped = rows.filter((r) => r.subsystem === 'unmapped').map((r) => r.name);

// --- C1 compatibility metric ------------------------------------------------

const all75 = {
    metric: 'all_75_paired_geomean',
    value: geomean(rows.map((r) => r.pairedGeomean)),
    compatibility_metric: true,
    route_priority_metric: false,
    comparableWith: ['reports/perf/qjs-align/2026-07-27/process-microbench.json (Phase 0, 1.3609)', 'Phase 6 closeout (1.3340, unpinned - historical only)'],
    note:
        'kept for continuity with Phase 0/6 only; it may not order the next line of work because 52 of 75 cases are startup-dominated',
};

// --- C2 classes -------------------------------------------------------------

const classOrder = ['execution-dominant', 'partially-resolvable', 'startup-dominated'];
const classes = classOrder.map((name) => {
    const members = rows.filter((r) => r.resolvabilityClass === name);
    return {
        class: name,
        caseCount: members.length,
        pairedGeomean: members.length ? geomean(members.map((r) => r.pairedGeomean)) : null,
        absoluteTotalDeltaMs: sum(members.map((r) => r.absoluteDeltaMs)),
        medianStartupShareQjs: median(members.map((r) => r.startupShareQjs)),
        stable: members.filter((r) => r.stability === 'stable' || r.stability === 'stable-within-run' || r.stability === 'stable-direction-only').length,
        unstable: members.filter((r) => r.stability === 'unstable' || r.stability === 'unstable-within-run').length,
        validated: members.filter((r) => r.validation.sampled).length,
        cases: members.map((r) => r.name),
    };
});

// --- C3 orderings -----------------------------------------------------------

const startupDeltaMs = runA.startupBaseline.zjs.median - runA.startupBaseline.qjs.median;
const orderingA = [...rows]
    .sort((a, b) => b.absoluteDeltaMs - a.absoluteDeltaMs)
    .map((r, index) => ({
        rank: index + 1,
        case: r.name,
        subsystem: r.subsystem,
        absoluteDeltaMs: r.absoluteDeltaMs,
        qjsMedianMs: r.qjsMedianMs,
        zjsMedianMs: r.zjsMedianMs,
        pairedRatio: r.pairedRatio,
        resolvabilityClass: r.resolvabilityClass,
        stability: r.stability,
    }));

const tiered = rows.filter((r) => r.resolvabilityClass !== 'startup-dominated');
const tieredLogTotal = sum(tiered.map((r) => Math.abs(Math.log(r.pairedGeomean))));
const orderingB = [...tiered]
    .sort((a, b) => Math.abs(Math.log(b.pairedGeomean)) - Math.abs(Math.log(a.pairedGeomean)))
    .map((r, index) => ({
        rank: index + 1,
        case: r.name,
        subsystem: r.subsystem,
        pairedRatio: r.pairedRatio,
        logContribution: Math.log(r.pairedGeomean),
        logShare: Math.abs(Math.log(r.pairedGeomean)) / tieredLogTotal,
        resolvabilityClass: r.resolvabilityClass,
    }));

const subsystems = [...new Set(rows.map((r) => r.subsystem))].sort();
const orderingC = subsystems
    .map((name) => {
        const members = rows.filter((r) => r.subsystem === name);
        const resolvable = members.filter((r) => r.resolvabilityClass !== 'startup-dominated');
        return {
            subsystem: name,
            caseCount: members.length,
            pairedGeomeanAll: geomean(members.map((r) => r.pairedGeomean)),
            resolvableCount: resolvable.length,
            pairedGeomeanResolvable: resolvable.length ? geomean(resolvable.map((r) => r.pairedGeomean)) : null,
            absoluteTotalDeltaMs: sum(members.map((r) => r.absoluteDeltaMs)),
            resolvableAbsoluteDeltaMs: sum(resolvable.map((r) => r.absoluteDeltaMs)),
            cases: members.map((r) => r.name),
        };
    })
    .concat([
        {
            subsystem: 'startup/bootstrap',
            caseCount: 0,
            pairedGeomeanAll: runA.startupBaseline.zjs.median / runA.startupBaseline.qjs.median,
            resolvableCount: 0,
            pairedGeomeanResolvable: null,
            absoluteTotalDeltaMs: startupDeltaMs * rows.length,
            resolvableAbsoluteDeltaMs: startupDeltaMs * rows.length,
            cases: [],
            note: `suite constant: ${rows.length} process launches x ${(startupDeltaMs * 1000).toFixed(1)} us`,
        },
    ])
    .sort((a, b) => b.absoluteTotalDeltaMs - a.absoluteTotalDeltaMs);

const top10 = orderingA
    .filter((entry) => {
        const row = rows.find((r) => r.name === entry.case);
        return row.resolvabilityClass !== 'startup-dominated';
    })
    .slice(0, 10)
    .map((entry) => {
        const r = rows.find((row) => row.name === entry.case);
        return {
            rank: entry.rank,
            case: r.name,
            subsystem: r.subsystem,
            pairedRatio: r.pairedRatio,
            absoluteDeltaMs: r.absoluteDeltaMs,
            startupShareQjs: r.startupShareQjs,
            resolvabilityClass: r.resolvabilityClass,
            qjsIqrMs: r.qjsIqrMs,
            zjsIqrMs: r.zjsIqrMs,
            pairedIqr: r.pairedP75 - r.pairedP25,
            validation: r.validation,
            buildInstanceB: r.buildInstanceB,
            stability: r.stability,
            routeEligible: r.routeEligible,
            relatedOptimisation: r.relatedOptimisation,
        };
    });

const resolvability = {
    tool: 'P7-70-resolvability',
    generatedFrom: path.resolve(opts['run-a']),
    engineCommit: runA.meta.zjs.commit,
    zjsSha256: runA.meta.zjs.sha256,
    qjsCommit: runA.meta.qjs.commit,
    qjsSha256: runA.meta.qjs.sha256,
    generation: runA.meta.startupBaselineIdentity.generation,
    policy: runA.contract.policyRef,
    startupBaseline: {
        qjsMedianMs: runA.startupBaseline.qjs.median,
        zjsMedianMs: runA.startupBaseline.zjs.median,
        qjsIqrMs: runA.startupBaseline.qjs.p75 - runA.startupBaseline.qjs.p25,
        zjsIqrMs: runA.startupBaseline.zjs.p75 - runA.startupBaseline.zjs.p25,
        ratio: runA.startupBaseline.zjs.median / runA.startupBaseline.qjs.median,
        deltaMs: startupDeltaMs,
        recollected: true,
        note: 'recollected in the same measurement generation as the cases; Phase 6 values (0.7907 / 0.9986) are NOT reused',
    },
    thresholds: {
        source: runA.contract.policyRef.path,
        note: 'thresholds are read from the repository policy, never from this file',
    },
    classes,
    cases: rows,
    unmappedCases: unmapped,
};

const pareto = {
    tool: 'P7-70-pareto',
    engineCommit: runA.meta.zjs.commit,
    baselineCommit: '042e4962',
    pinnedQjsCommit: runA.meta.qjs.commit,
    generation: runA.meta.startupBaselineIdentity.generation,
    tiers: {
        C1: all75,
        C2: classes,
        C3: { orderingA_absoluteTime: orderingA, orderingB_tieredLogContribution: orderingB, orderingC_subsystem: orderingC },
    },
    top10ExecutionRelevant: top10,
    voided: {
        array_map_callback_2_618:
            'voided by P7-40 (stale binary + invalid affinity); the current pinned measurement is reported here instead',
        startupAdjustedGeometricMean: 'never emitted; diagnostic only',
        historical_23_52_split: 'not carried over; the class split here is recomputed from the 042e4962 data',
    },
};

// --- deterministic stdout checksums -----------------------------------------
// The runner only keeps stdout on a mismatch, so the per-case checksum is taken
// here by replaying each case source once through both binaries. This is an
// output-identity check, not a timing measurement.

const suiteModule = await import(path.resolve(import.meta.dir, '../../../../../../tools/compare/microbench_cases.js'));
const suiteSourceByName = Object.fromEntries(suiteModule.cases.filter((c) => c.source).map((c) => [c.name, `${c.source}\n`]));

function stdoutChecksums(report) {
    const out = {};
    const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? '/tmp', 'p7-70-checksum-'));
    try {
        for (const [name, entry] of Object.entries(report.meta.caseSources ?? {})) {
            const script = path.join(tmp, `${name}.js`);
            const body = suiteSourceByName[name];
            if (body == null) {
                out[name] = { available: false, reason: `case ${name} is not in the microbench suite module` };
                continue;
            }
            const rebuiltSha = new Bun.CryptoHasher('sha256').update(body).digest('hex');
            if (rebuiltSha !== entry.sourceSha256) {
                out[name] = {
                    available: false,
                    reason: `reconstructed source SHA ${rebuiltSha} does not match the recorded ${entry.sourceSha256}`,
                };
                continue;
            }
            const source = Buffer.from(body);
            fs.writeFileSync(script, source);
            const run = (bin) => {
                const proc = Bun.spawnSync({ cmd: [bin, script], stdout: 'pipe', stderr: 'pipe' });
                return {
                    sha256: new Bun.CryptoHasher('sha256').update(proc.stdout ?? new Uint8Array()).digest('hex'),
                    exitCode: proc.exitCode,
                };
            };
            const q = run(report.meta.qjs.binary);
            const z = run(report.meta.zjs.binary);
            out[name] = {
                available: true,
                qjsStdoutSha256: q.sha256,
                zjsStdoutSha256: z.sha256,
                identical: q.sha256 === z.sha256,
                qjsExitCode: q.exitCode,
                zjsExitCode: z.exitCode,
            };
        }
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
    return out;
}

const checksums = opts['no-checksums'] ? {} : stdoutChecksums(runA);
for (const row of resolvability.cases) row.stdoutChecksum = checksums[row.name] ?? { available: false };

// --- trimmed committable artifacts ------------------------------------------
// Raw samples, execution order and validation survive; the PMU audit rows and
// peak-RSS probe samples stay in .zig-cache/perf/p7-70/.

function trim(report, label) {
    if (!report) return null;
    return {
        artifact: label,
        tool: report.tool,
        suite: report.suite,
        timestamp: report.timestamp,
        complete: report.complete,
        headline: report.headline,
        summary: report.summary,
        contract: {
            policyRef: report.contract.policyRef,
            complete: report.contract.complete,
            errorClass: report.contract.errorClass,
            violations: report.contract.violations,
            sampleContract: {
                samples: report.contract.sampleContract.samples,
                firstPositionCounts: report.contract.sampleContract.firstPositionCounts,
                positionCounts: report.contract.sampleContract.positionCounts,
                declaredOrders: report.contract.sampleContract.declaredOrders,
                executedOrders: report.contract.sampleContract.executedOrders,
            },
            affinityAttestation: report.contract.affinityAttestation,
        },
        meta: report.meta,
        startupBaseline: {
            status: report.startupBaseline.status,
            identity: report.startupBaseline.identity,
            qjs: report.startupBaseline.qjs,
            zjs: report.startupBaseline.zjs,
            ratio: report.startupBaseline.ratio,
            paired: report.startupBaseline.paired,
            pairs: report.startupBaseline.pairs,
            executedOrders: report.startupBaseline.executedOrders,
            validation: report.startupBaseline.validation,
        },
        cases: okCases(report).map((row) => ({
            name: row.name,
            quickjsName: row.quickjsName,
            category: row.category,
            subsystem: subsystemOf(row),
            status: row.status,
            sourcePath: row.sourcePath,
            sourceSha256: row.sourceSha256,
            generation: row.generation,
            qjsSamplesMs: row.qjs.samples,
            zjsSamplesMs: row.zjs.samples,
            executedOrders: row.executedOrders,
            warmupOrders: row.warmupOrders,
            qjs: { median: row.qjs.median, p25: row.qjs.p25, p75: row.qjs.p75, iqr: row.qjs.p75 - row.qjs.p25, min: row.qjs.min, max: row.qjs.max },
            zjs: { median: row.zjs.median, p25: row.zjs.p25, p75: row.zjs.p75, iqr: row.zjs.p75 - row.zjs.p25, min: row.zjs.min, max: row.zjs.max },
            paired: row.paired,
            absoluteDeltaMs: row.zjs.median - row.qjs.median,
            startupShareQjs: row.resolvability.startupShareQjs,
            startupShareZjs: row.resolvability.startupShareZjs,
            resolvabilityClass: row.resolvability.resolvabilityClass,
            startupAdjusted: row.startupAdjusted,
            validation: row.validation,
            stdoutChecksum: checksums[row.name] ?? { available: false },
        })),
    };
}

fs.writeFileSync(path.join(outdir, 'microbench-75-run-a.json'), `${JSON.stringify(trim(runA, 'microbench-75-run-a'), null, 2)}\n`);
if (runB) {
    fs.writeFileSync(
        path.join(outdir, 'microbench-validation-run-b.json'),
        `${JSON.stringify(trim(runB, 'microbench-validation-run-b'), null, 2)}\n`,
    );
}
if (buildB) {
    fs.writeFileSync(
        path.join(outdir, 'microbench-build-instance-b.json'),
        `${JSON.stringify(trim(buildB, 'microbench-build-instance-b'), null, 2)}\n`,
    );
}

// --- startup baseline -------------------------------------------------------

const startupArtifact = {
    tool: 'P7-70-startup-baseline',
    generation: runA.meta.startupBaselineIdentity.generation,
    identity: runA.startupBaseline.identity,
    recollectedInThisGeneration: true,
    doNotReuse: {
        phase6: { qjsMs: 0.7907, zjsMs: 0.9986, reason: 'unpinned collection, different measurement generation' },
        phase0: { qjsMs: 0.4324, zjsMs: 0.5552, reason: 'different measurement generation' },
    },
    runs: [
        { artifact: 'microbench-75-run-a', qjs: runA.startupBaseline.qjs, zjs: runA.startupBaseline.zjs, ratio: runA.startupBaseline.ratio },
        ...(runB ? [{ artifact: 'microbench-validation-run-b', qjs: runB.startupBaseline.qjs, zjs: runB.startupBaseline.zjs, ratio: runB.startupBaseline.ratio }] : []),
        ...(buildB ? [{ artifact: 'microbench-build-instance-b', qjs: buildB.startupBaseline.qjs, zjs: buildB.startupBaseline.zjs, ratio: buildB.startupBaseline.ratio }] : []),
    ],
};
fs.writeFileSync(path.join(outdir, 'startup-baseline.json'), `${JSON.stringify(startupArtifact, null, 2)}\n`);

fs.writeFileSync(path.join(outdir, 'resolvability.json'), `${JSON.stringify(resolvability, null, 2)}\n`);
fs.writeFileSync(path.join(outdir, 'pareto-current.json'), `${JSON.stringify(pareto, null, 2)}\n`);

// --- markdown ---------------------------------------------------------------

const f = (value, digits = 3) => (value == null ? '—' : Number(value).toFixed(digits));
const lines = [];
lines.push('# P7-70 当前权威 Pareto（`042e4962`，绑核 CPU 19，8 样本平衡）');
lines.push('');
lines.push(`- 引擎二进制：\`zjs-A\` sha256 \`${runA.meta.zjs.sha256.slice(0, 16)}…\`，commit \`${runA.meta.zjs.commit.slice(0, 8)}\``);
lines.push(`- 对照：pinned qjs \`${runA.meta.qjs.commit.slice(0, 8)}\` VERSION ${runA.meta.qjs.version}，sha256 \`${runA.meta.qjs.sha256.slice(0, 16)}…\``);
lines.push(`- 测量代次：\`${runA.meta.startupBaselineIdentity.generation}\`；启动基线在同一代次重采`);
lines.push(`- 启动基线：qjs ${f(runA.startupBaseline.qjs.median)} ms / zjs ${f(runA.startupBaseline.zjs.median)} ms，比值 ${f(resolvability.startupBaseline.ratio)}，差额 ${f(startupDeltaMs * 1000, 1)} µs`);
lines.push('');
lines.push('## C1 兼容口径');
lines.push('');
lines.push(`\`all_75_paired_geomean = ${f(all75.value, 4)}\`（\`compatibility_metric = true\`，\`route_priority_metric = false\`）。`);
lines.push('该数字只用于与 Phase 0 / Phase 6 对齐，不得用来给下一条线排序。');
lines.push('');
lines.push('## C2 按当前实测启动占比分档');
lines.push('');
lines.push('| 档位 | case 数 | paired geomean | 绝对差合计 | 启动占比中位数 | stable | unstable | 有验证轮 |');
lines.push('|------|---------|----------------|------------|----------------|--------|----------|----------|');
for (const c of classes) {
    lines.push(
        `| ${c.class} | ${c.caseCount} | ${f(c.pairedGeomean, 4)} | ${f(c.absoluteTotalDeltaMs, 3)} ms | ${f(c.medianStartupShareQjs * 100, 1)}% | ${c.stable} | ${c.unstable} | ${c.validated} |`,
    );
}
lines.push('');
lines.push('## C3-A 绝对时间贡献（工程优先级）');
lines.push('');
lines.push('| # | case | 子系统 | zjs−qjs | qjs → zjs | paired | 分档 |');
lines.push('|---|------|--------|---------|-----------|--------|------|');
for (const e of orderingA.slice(0, 20)) {
    lines.push(
        `| ${e.rank} | \`${e.case}\` | ${e.subsystem} | ${e.absoluteDeltaMs >= 0 ? '+' : ''}${f(e.absoluteDeltaMs)} ms | ${f(e.qjsMedianMs, 2)} → ${f(e.zjsMedianMs, 2)} | ${f(e.pairedRatio)} | ${e.resolvabilityClass} |`,
    );
}
lines.push('');
lines.push('## C3-B 分档 log 贡献（仅 execution-dominant + partially-resolvable）');
lines.push('');
lines.push('| # | case | 子系统 | paired | log 份额 | 分档 |');
lines.push('|---|------|--------|--------|----------|------|');
for (const e of orderingB.slice(0, 15)) {
    lines.push(`| ${e.rank} | \`${e.case}\` | ${e.subsystem} | ${f(e.pairedRatio)} | ${f(e.logShare * 100, 2)}% | ${e.resolvabilityClass} |`);
}
lines.push('');
lines.push('## C3-C 子系统聚类');
lines.push('');
lines.push('| 子系统 | case 数 | geomean(全部) | 可分辨数 | geomean(可分辨) | 绝对差合计 |');
lines.push('|--------|---------|---------------|----------|------------------|------------|');
for (const s of orderingC) {
    lines.push(
        `| ${s.subsystem} | ${s.caseCount} | ${f(s.pairedGeomeanAll, 4)} | ${s.resolvableCount} | ${f(s.pairedGeomeanResolvable, 4)} | ${f(s.absoluteTotalDeltaMs, 3)} ms |`,
    );
}
lines.push('');
lines.push('## 当前 top 10（执行可分辨，按绝对差）');
lines.push('');
lines.push('| # | case | paired | 绝对差 | 启动占比 | 分档 | paired IQR | 主轮 vs 验证轮 | 已有归因 |');
lines.push('|---|------|--------|--------|----------|------|------------|----------------|----------|');
for (const t of top10) {
    const v = t.validation.sampled
        ? `${f(t.validation.pairedRatio)}，同向=${t.validation.directionAgrees ? '是' : '否'}，IQR 重叠=${t.validation.iqrOverlap ? '是' : '否'}`
        : '未采样';
    lines.push(
        `| ${t.rank} | \`${t.case}\` | ${f(t.pairedRatio)} | +${f(t.absoluteDeltaMs)} ms | ${f(t.startupShareQjs * 100, 1)}% | ${t.resolvabilityClass} | ${f(t.pairedIqr, 4)} | ${v} | ${t.relatedOptimisation ? '是' : '否'} |`,
    );
}
lines.push('');
fs.writeFileSync(path.join(outdir, 'pareto-current.md'), `${lines.join('\n')}\n`);

console.log(`all_75_paired_geomean = ${all75.value.toFixed(4)}`);
for (const c of classes) console.log(`${c.class}: ${c.caseCount} cases, geomean ${c.pairedGeomean?.toFixed(4)}, delta ${c.absoluteTotalDeltaMs.toFixed(3)} ms`);
if (unmapped.length) console.log(`unmapped cases: ${unmapped.join(', ')}`);
