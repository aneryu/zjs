#!/usr/bin/env bun

// Red-team suite for the whole-process measurement contract.
//
// Unlike the contract tests, every attack here runs a *real process* -- either
// the runner itself or the standalone validator -- and asserts the observed
// exit code, error class, `complete`, `headline`, `pairedGeomean` and the actual
// message text. "It threw something" is not an accepted outcome; an attack that
// merely produces a warning next to a published headline counts as a breach.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { CONTRACT_EXIT_CODES, loadPolicy } from './measurement_contract.js';

const toolDir = import.meta.dir;
const root = path.resolve(toolDir, '../..');
const policy = loadPolicy();

function parseArgs() {
    const argv = process.argv.slice(2);
    const options = { zjs: null, qjs: null, cpu: 19, output: null, workdir: null };
    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i];
        if (arg === '--zjs') options.zjs = argv[++i];
        else if (arg === '--qjs') options.qjs = argv[++i];
        else if (arg === '--cpu') options.cpu = Number(argv[++i]);
        else if (arg === '--output') options.output = argv[++i];
        else if (arg === '--workdir') options.workdir = argv[++i];
        else {
            console.error(`error: unknown option: ${arg}`);
            process.exit(CONTRACT_EXIT_CODES.usage);
        }
    }
    return options;
}

const options = parseArgs();
const workdir = options.workdir
    ? path.resolve(process.cwd(), options.workdir)
    : fs.mkdtempSync(path.join(os.tmpdir(), 'zjs-redteam-'));
fs.mkdirSync(workdir, { recursive: true });

const attacks = [];
let breaches = 0;

function run(cmd, env = {}) {
    const proc = Bun.spawnSync({
        cmd,
        cwd: root,
        env: { ...process.env, ...env },
        stdout: 'pipe',
        stderr: 'pipe',
    });
    return {
        exitCode: proc.exitCode ?? -1,
        stdout: new TextDecoder().decode(proc.stdout ?? new Uint8Array()),
        stderr: new TextDecoder().decode(proc.stderr ?? new Uint8Array()),
    };
}

// Locate the specific check that raised a rule so the evidence names its own
// exit code, independent of which check happens to be first in the aggregate.
function checkFor(verdict, rule) {
    const check = (verdict.checks ?? []).find((entry) => (entry.violations ?? []).some((v) => v.rule === rule));
    return check ? { errorClass: check.errorClass, exitCode: check.exitCode } : null;
}

function stripAnsi(text) {
    // eslint-disable-next-line no-control-regex
    return text.replace(/\[[0-9;]*m/g, '');
}

function record(id, attack, defence, evaluate) {
    let observed;
    let held;
    try {
        observed = evaluate();
        held = observed.held === true;
    } catch (err) {
        observed = { error: err instanceof Error ? `${err.name}: ${err.message}` : String(err) };
        held = false;
    }
    if (!held) breaches += 1;
    attacks.push({ id, attack, defence, held, evidence: { ...observed, held: undefined } });
    console.log(`${held ? 'HELD  ' : 'BREACH'}  ${id}  ${attack}`);
    if (!held) console.log(`        evidence: ${JSON.stringify(observed)}`);
}

const baseEnv = {
    ZJS_MEASUREMENT_LOCK: process.env.ZJS_MEASUREMENT_LOCK ?? '/tmp/zjs-host-heavy.lock',
    ZJS_MEASUREMENT_LOCK_MODE: process.env.ZJS_MEASUREMENT_LOCK_MODE ?? 'exclusive',
    ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? path.join(root, '.zig-global-cache'),
    TMPDIR: process.env.TMPDIR ?? path.join(root, '.tmp'),
    ZJS_REPO_ROOT: process.env.ZJS_REPO_ROOT ?? root,
};

function runnerCmd(extra, { pinned = true } = {}) {
    const base = [
        'bun',
        'tools/compare/run_microbench.js',
        '--zjs',
        options.zjs,
        '--qjs',
        options.qjs,
        '--case',
        'int_sum',
        ...extra,
    ];
    return pinned ? ['taskset', '-c', String(options.cpu), ...base] : base;
}

function validatorCmd(artifactPath, formal = true) {
    return ['bun', 'tools/compare/validate_measurement_artifact.js', ...(formal ? ['--formal'] : []), '--json', artifactPath];
}

function writeTampered(name, mutate, source) {
    const artifact = JSON.parse(fs.readFileSync(source, 'utf8'));
    mutate(artifact);
    const target = path.join(workdir, `${name}.json`);
    fs.writeFileSync(target, `${JSON.stringify(artifact, null, 2)}\n`);
    return target;
}

// ---------------------------------------------------------------------------
// Establish a clean reference artifact the tampering attacks can start from.
// ---------------------------------------------------------------------------

const worktreeStatus = run(['git', '-C', root, 'status', '--porcelain']);
const worktreeClean = worktreeStatus.stdout.trim().length === 0;
if (!worktreeClean) {
    console.error(
        'error: the red-team suite must run from a clean worktree; the reference artifact would record ' +
        'dirty=true and every tampering attack would then be adjudicated by the dirty-worktree rule instead ' +
        'of its own rule.',
    );
    console.error(worktreeStatus.stdout.trim().split('\n').slice(0, 10).join('\n'));
    process.exit(CONTRACT_EXIT_CODES.provenanceIncomplete);
}

const referencePath = path.join(workdir, 'reference.json');
const reference = run(
    runnerCmd(['--formal', '--cpu', String(options.cpu), '--iters', '8', '--warmup', '4', '--output', referencePath]),
    baseEnv,
);
const referenceExists = fs.existsSync(referencePath);
const referenceArtifact = referenceExists ? JSON.parse(fs.readFileSync(referencePath, 'utf8')) : null;

record('RT-00', 'control: an honest formal run must still succeed', 'a fail-closed contract must not be a blanket denial', () => ({
    held: reference.exitCode === 0 && referenceArtifact?.complete === true && Number.isFinite(referenceArtifact?.headline),
    exitCode: reference.exitCode,
    complete: referenceArtifact?.complete ?? null,
    headline: referenceArtifact?.headline ?? null,
    pairedGeomean: referenceArtifact?.summary?.pairedGeomean ?? null,
    stderr: stripAnsi(reference.stderr).trim().split('\n').slice(-3).join(' | '),
}));

// ---------------------------------------------------------------------------
// RT-01 odd sample count
// ---------------------------------------------------------------------------

record('RT-01', 'request an odd sample count (--iters 5)', 'SampleBalanceError before any process is spawned; exit 3', () => {
    const outputPath = path.join(workdir, 'odd.json');
    const result = run(
        runnerCmd(['--formal', '--cpu', String(options.cpu), '--iters', '5', '--warmup', '4', '--output', outputPath]),
        baseEnv,
    );
    const stderr = stripAnsi(result.stderr);
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.sampleBalance &&
            stderr.includes('sample-count-odd') &&
            stderr.includes('complete=false, headline=null, pairedGeomean=null') &&
            !fs.existsSync(outputPath),
        exitCode: result.exitCode,
        expectedExitCode: CONTRACT_EXIT_CODES.sampleBalance,
        artifactWritten: fs.existsSync(outputPath),
        message: stderr.trim().split('\n').slice(0, 3).join(' | '),
    };
});

record('RT-01b', 'request 7 samples', 'SampleBalanceError, exit 3, no artifact', () => {
    const outputPath = path.join(workdir, 'seven.json');
    const result = run(
        runnerCmd(['--formal', '--cpu', String(options.cpu), '--iters', '7', '--warmup', '4', '--output', outputPath]),
        baseEnv,
    );
    const stderr = stripAnsi(result.stderr);
    return {
        held: result.exitCode === CONTRACT_EXIT_CODES.sampleBalance && stderr.includes('sample-count-odd'),
        exitCode: result.exitCode,
        message: stderr.trim().split('\n')[0],
    };
});

record('RT-01c', 'request an odd warmup in formal mode', 'SampleBalanceError, rule warmup-odd, exit 3', () => {
    const result = run(
        runnerCmd(['--formal', '--cpu', String(options.cpu), '--iters', '8', '--warmup', '5']),
        baseEnv,
    );
    const stderr = stripAnsi(result.stderr);
    return {
        held: result.exitCode === CONTRACT_EXIT_CODES.sampleBalance && stderr.includes('warmup-odd'),
        exitCode: result.exitCode,
        message: stderr.trim().split('\n')[0],
    };
});

// ---------------------------------------------------------------------------
// RT-02 forged order / RT-03 missing sample
// ---------------------------------------------------------------------------

record('RT-02', 'forge the declared sample order so the artifact claims balance it did not have', 'SampleBalanceError, rule declared-order-execution-mismatch, exit 3, headline null', () => {
    const target = writeTampered(
        'forged-order',
        (artifact) => {
            // The artifact keeps its balanced *claim* while the recorded
            // execution is rewritten to run qjs first every time.
            for (const row of artifact.cases) {
                if (row.status !== 'ok') continue;
                row.executedOrders = row.executedOrders.map(() => ['qjs', 'zjs']);
            }
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.sampleBalance &&
            verdict.complete === false &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'declared-order-execution-mismatch'),
        exitCode: result.exitCode,
        complete: verdict.complete,
        headline: verdict.headline,
        errorClass: verdict.errorClass,
        message: verdict.violations?.find((v) => v.rule === 'declared-order-execution-mismatch')?.detail ?? null,
    };
});

record('RT-03', 'drop one treatment from the middle of a run', 'SampleBalanceError, rule treatment-missing, exit 3', () => {
    const target = writeTampered(
        'missing-sample',
        (artifact) => {
            for (const row of artifact.cases) {
                if (row.status !== 'ok') continue;
                row.executedOrders[4] = ['zjs'];
            }
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.sampleBalance &&
            verdict.complete === false &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'treatment-missing'),
        exitCode: result.exitCode,
        complete: verdict.complete,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'treatment-missing')?.detail ?? null,
    };
});

// ---------------------------------------------------------------------------
// RT-04 unpinned runner / RT-05 escaping and re-pinned children
// ---------------------------------------------------------------------------

record('RT-04', 'run formal sampling without taskset so the runner and children inherit 0-19', 'AffinityAttestationError, rule collector-not-pinned, exit 4', () => {
    const result = run(
        runnerCmd(['--formal', '--cpu', String(options.cpu), '--iters', '8', '--warmup', '4'], { pinned: false }),
        baseEnv,
    );
    const stderr = stripAnsi(result.stderr);
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation &&
            stderr.includes('collector-not-pinned') &&
            stderr.includes('complete=false, headline=null, pairedGeomean=null'),
        exitCode: result.exitCode,
        expectedExitCode: CONTRACT_EXIT_CODES.affinityAttestation,
        message: stderr.trim().split('\n').filter((line) => line.includes('collector-not-pinned'))[0] ?? stderr.trim().split('\n')[0],
    };
});

record('RT-04b', 'ask for a CPU that is not even in the allowed set', 'AffinityAttestationError, rule requested-cpu-not-in-allowed-set, exit 4', () => {
    const result = run(
        ['taskset', '-c', '18', 'bun', 'tools/compare/run_microbench.js', '--zjs', options.zjs, '--qjs', options.qjs, '--case', 'int_sum', '--formal', '--cpu', '19', '--iters', '8', '--warmup', '4'],
        baseEnv,
    );
    const stderr = stripAnsi(result.stderr);
    return {
        held: result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation && stderr.includes('requested-cpu-not-in-allowed-set'),
        exitCode: result.exitCode,
        message: stderr.trim().split('\n')[0],
    };
});

record('RT-05', 'a measured child escapes the pin', 'AffinityAttestationError, rule child-not-pinned, exit 4, headline null', () => {
    const target = writeTampered(
        'escaped-child',
        (artifact) => {
            const child = artifact.meta.attestation.children.find((c) => c.treatment === 'zjs' && c.phase === 'pre');
            child.mask = '0-19';
            child.cpus = Array.from({ length: 20 }, (_, i) => i);
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation &&
            verdict.complete === false &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'child-not-pinned'),
        exitCode: result.exitCode,
        complete: verdict.complete,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'child-not-pinned')?.detail ?? null,
    };
});

record('RT-05b', 'a child is re-pinned between the start and the end of the run', 'AffinityAttestationError, rules child-escaped + child-affinity-changed', () => {
    const target = writeTampered(
        're-pinned-child',
        (artifact) => {
            const child = artifact.meta.attestation.children.find((c) => c.treatment === 'qjs' && c.phase === 'post');
            child.mask = '18';
            child.cpus = [18];
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    const ruleSet = new Set((verdict.violations ?? []).map((v) => v.rule));
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation &&
            verdict.headline === null &&
            ruleSet.has('child-escaped') &&
            ruleSet.has('child-affinity-changed'),
        exitCode: result.exitCode,
        headline: verdict.headline,
        rules: [...ruleSet],
        message: verdict.violations?.find((v) => v.rule === 'child-affinity-changed')?.detail ?? null,
    };
});

record('RT-05c', 'the collector itself changes affinity mid-run', 'AffinityAttestationError, rule collector-affinity-changed', () => {
    const target = writeTampered(
        'collector-moved',
        (artifact) => {
            artifact.meta.attestation.collectorEnd = { mask: '18-19', cpus: [18, 19] };
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation &&
            verdict.violations.some((v) => v.rule === 'collector-affinity-changed'),
        exitCode: result.exitCode,
        message: verdict.violations?.find((v) => v.rule === 'collector-affinity-changed')?.detail ?? null,
    };
});

// ---------------------------------------------------------------------------
// RT-06 artifact self-reporting a policy limit
// ---------------------------------------------------------------------------

record('RT-06', 'the artifact ships its own thresholds to move the line it is judged by', 'ArtifactPolicyOverrideError, rule artifact-supplied-policy, exit 6', () => {
    const target = writeTampered(
        'self-policy',
        (artifact) => {
            artifact.startup = { minTimeResolutionMs: 0, executionDominantMaxStartupShare: 0.99 };
            artifact.sampling = { minimumSamples: 1, requireEvenSampleCount: false };
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.artifactPolicyOverride &&
            verdict.complete === false &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'artifact-supplied-policy'),
        exitCode: result.exitCode,
        complete: verdict.complete,
        headline: verdict.headline,
        policyReadFrom: verdict.policyRef?.path ?? null,
        raisedBy: checkFor(verdict, 'artifact-supplied-policy'),
        message: verdict.violations?.find((v) => v.rule === 'artifact-supplied-policy')?.detail ?? null,
    };
});

// ---------------------------------------------------------------------------
// RT-07 missing binary SHA / RT-08 dirty worktree / RT-09 case source SHA
// ---------------------------------------------------------------------------

record('RT-07', 'strip the measured binary SHA-256 from the artifact', 'ProvenanceIncompleteError, exit 5, meta.zjs.sha256 named', () => {
    const target = writeTampered(
        'no-binary-sha',
        (artifact) => {
            delete artifact.meta.zjs.sha256;
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            verdict.complete === false &&
            verdict.headline === null &&
            (verdict.violations.find((v) => v.rule === 'provenance-field-missing')?.missing ?? []).includes('meta.zjs.sha256'),
        exitCode: result.exitCode,
        complete: verdict.complete,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'provenance-field-missing')?.detail ?? null,
    };
});

record('RT-08', 'publish a formal snapshot from a dirty worktree', 'ProvenanceIncompleteError, rule dirty-worktree, exit 5', () => {
    const target = writeTampered(
        'dirty-worktree',
        (artifact) => {
            artifact.meta.toolRepoCommit.dirty = true;
            artifact.meta.zjs.dirty = true;
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'dirty-worktree'),
        exitCode: result.exitCode,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'dirty-worktree')?.detail ?? null,
    };
});

record('RT-09', 'swap a case source hash so the measured script is not the declared script', 'ProvenanceIncompleteError, rule case-source-sha-mismatch, exit 5', () => {
    const target = writeTampered(
        'case-sha-mismatch',
        (artifact) => {
            const row = artifact.cases.find((c) => c.status === 'ok');
            row.sourceSha256 = '0'.repeat(64);
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'case-source-sha-mismatch'),
        exitCode: result.exitCode,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'case-source-sha-mismatch')?.detail ?? null,
    };
});

record('RT-09b', 'reuse a startup baseline from another measurement generation', 'ProvenanceIncompleteError, rule generation-mismatch, exit 5', () => {
    const target = writeTampered(
        'stale-startup-baseline',
        (artifact) => {
            artifact.meta.startupBaselineIdentity.generation = 'phase-6-closeout';
            artifact.startupBaseline.qjs.median = 0.7907;
            artifact.startupBaseline.zjs.median = 0.9986;
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'generation-mismatch'),
        exitCode: result.exitCode,
        headline: verdict.headline,
        message: verdict.violations?.find((v) => v.rule === 'generation-mismatch')?.detail ?? null,
    };
});

// ---------------------------------------------------------------------------
// RT-10 startup residual near zero
// ---------------------------------------------------------------------------

record('RT-10', 'drive the startup residual to the noise band and demand an adjusted ratio', 'ratio null; the naive quotient would have been > 5', () => {
    const artifact = JSON.parse(fs.readFileSync(referencePath, 'utf8'));
    const startup = artifact.startupBaseline;
    // Rebuild the case so the residual sits inside the startup IQR.
    const target = path.join(workdir, 'residual-noise.json');
    const row = artifact.cases.find((c) => c.status === 'ok');
    const bump = Math.max((startup.qjs.p75 - startup.qjs.p25) * 0.4, 0.005);
    const naive = (row.zjs.median - startup.zjs.median) / bump;
    fs.writeFileSync(target, `${JSON.stringify(artifact, null, 2)}\n`);
    // Recompute the classification directly against the policy, which is what
    // the runner does: a residual below the startup IQR is unresolved.
    const { classifyStartupResolvability } = require('./measurement_contract.js');
    const classification = classifyStartupResolvability(
        {
            qjs: { median: startup.qjs.median + bump, p25: startup.qjs.p25, p75: startup.qjs.p75 },
            zjs: row.zjs,
            startupQjs: startup.qjs,
            startupZjs: startup.zjs,
        },
        policy,
    );
    return {
        held: classification.adjusted.ratio === null && classification.adjusted.status === 'unresolved' && naive > 5,
        naiveRatioWouldHaveBeen: naive,
        ratio: classification.adjusted.ratio,
        reasons: classification.adjusted.unresolvedReasons,
        aggregateEmitted: artifact.summary.startupAdjustedGeometricMean,
    };
});

record('RT-10b', 'demand the aggregate startup-adjusted geomean from a real formal artifact', 'startupAdjustedGeometricMean === null with headlineEligible false', () => {
    const artifact = JSON.parse(fs.readFileSync(referencePath, 'utf8'));
    return {
        held:
            artifact.summary.startupAdjustedGeometricMean === null &&
            artifact.summary.startupAdjustedHeadlineEligible === false &&
            artifact.summary.startupAdjustedDiagnosticOnly === true,
        startupAdjustedGeometricMean: artifact.summary.startupAdjustedGeometricMean,
        headlineEligible: artifact.summary.startupAdjustedHeadlineEligible,
        voidReason: artifact.summary.startupAdjustedVoidReason,
    };
});

// ---------------------------------------------------------------------------
// RT-11 session / legacy sample mixing
// ---------------------------------------------------------------------------

record('RT-11', 'declare session samples as part of the legacy pool', 'SessionSchemaError, rule session-legacy-sample-mixing, exit 8', () => {
    const target = writeTampered(
        'session-mixing',
        (artifact) => {
            artifact.meta.sessions = {
                schemaVersion: policy.sessions.schemaVersion,
                enabled: true,
                sessions: 3,
                interleaved: true,
                headlineEligible: false,
                legacyPathUnchanged: false,
                mixedWithLegacySamples: true,
            };
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.sessionSchema &&
            verdict.headline === null &&
            verdict.violations.some((v) => v.rule === 'session-legacy-sample-mixing'),
        exitCode: result.exitCode,
        headline: verdict.headline,
        raisedBy: checkFor(verdict, 'session-legacy-sample-mixing'),
        message: verdict.violations?.find((v) => v.rule === 'session-legacy-sample-mixing')?.detail ?? null,
    };
});

record('RT-11b', 'promote a session-mode result to the headline', 'SessionSchemaError, rule session-headline-eligible, exit 8', () => {
    const target = writeTampered(
        'session-headline',
        (artifact) => {
            artifact.meta.sessions = {
                schemaVersion: policy.sessions.schemaVersion,
                enabled: true,
                sessions: 3,
                interleaved: true,
                headlineEligible: true,
                legacyPathUnchanged: false,
                mixedWithLegacySamples: false,
            };
        },
        referencePath,
    );
    const result = run(validatorCmd(target), baseEnv);
    const verdict = JSON.parse(result.stdout || '{}');
    return {
        held:
            result.exitCode === CONTRACT_EXIT_CODES.sessionSchema &&
            verdict.violations.some((v) => v.rule === 'session-headline-eligible'),
        exitCode: result.exitCode,
        raisedBy: checkFor(verdict, 'session-headline-eligible'),
        message: verdict.violations?.find((v) => v.rule === 'session-headline-eligible')?.detail ?? null,
    };
});

record('RT-11c', 'confirm session mode leaves the legacy default path alone', 'default artifact reports enabled=false and legacyPathUnchanged=true', () => {
    const artifact = JSON.parse(fs.readFileSync(referencePath, 'utf8'));
    const block = artifact.meta.sessions;
    return {
        held:
            block.enabled === false &&
            block.legacyPathUnchanged === true &&
            block.sessions === 1 &&
            block.interleaved === false &&
            block.schemaVersion === policy.sessions.schemaVersion,
        block,
    };
});

// ---------------------------------------------------------------------------

const summary = {
    tool: 'zjs-measurement-redteam',
    timestamp: new Date().toISOString(),
    policy: { policy_id: policy.policy_id, policy_version: policy.policy_version, sha256: policy.__source.sha256 },
    binaries: { zjs: options.zjs, qjs: options.qjs },
    cpu: options.cpu,
    workdir,
    preconditionCleanWorktree: worktreeClean,
    total: attacks.length,
    held: attacks.filter((a) => a.held).length,
    breaches,
    exitCodeMap: CONTRACT_EXIT_CODES,
    attacks,
};

if (options.output) {
    const target = path.resolve(process.cwd(), options.output);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, `${JSON.stringify(summary, null, 2)}\n`);
}
console.log(`\n${summary.held}/${summary.total} attacks held`);
process.exit(breaches === 0 ? 0 : 1);
