#!/usr/bin/env bun

// Contract tests for the whole-process measurement contract.
//
// Every assertion is specific: exit code, error class, the offending rule id,
// and the message text. "It threw something" is not an accepted outcome.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
    CONTRACT_EXIT_CODES,
    classifyStartupResolvability,
    loadPolicy,
    startupAdjustedSummary,
    validateAffinityAttestation,
    validatePhaseSampling,
    validateProvenance,
    validateSampleContract,
    validateSessionSchema,
    validateStageAttribution,
    validateWarmupContract,
    validateWorktreeCleanliness,
    validateGenerationCoherence,
    assertNoSelfSuppliedPolicy,
} from './measurement_contract.js';

const policy = loadPolicy();
const results = [];
let failures = 0;

function record(id, area, description, expectation, evaluate) {
    let observed;
    let status;
    let error = null;
    try {
        observed = evaluate();
        status = observed.pass ? 'pass' : 'fail';
    } catch (err) {
        observed = { pass: false, detail: err instanceof Error ? `${err.name}: ${err.message}` : String(err) };
        status = 'error';
        error = observed.detail;
    }
    if (status !== 'pass') failures += 1;
    results.push({ id, area, description, expectation, status, observed: { ...observed, pass: undefined }, error });
    const mark = status === 'pass' ? 'PASS' : 'FAIL';
    console.log(`${mark}  ${id}  ${description}`);
    if (status !== 'pass') console.log(`      expected: ${expectation}\n      observed: ${JSON.stringify(observed)}`);
}

function abba(count) {
    return Array.from({ length: count }, (_, index) => (index % 2 === 0 ? ['qjs', 'zjs'] : ['zjs', 'qjs']));
}

function rules(result) {
    return result.violations.map((violation) => violation.rule);
}

function detailFor(result, rule) {
    return result.violations.find((violation) => violation.rule === rule)?.detail ?? null;
}

// ---------------------------------------------------------------------------
// A1 - sample count and order
// ---------------------------------------------------------------------------

record('A1-01', 'sampling', 'samples=5 fails closed', 'SampleBalanceError, rule sample-count-odd, exit 3', () => {
    const orders = abba(5);
    const result = validateSampleContract({ samples: 5, declaredOrders: orders, executedOrders: orders }, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'SampleBalanceError' &&
            result.exitCode === CONTRACT_EXIT_CODES.sampleBalance &&
            rules(result).includes('sample-count-odd') &&
            rules(result).includes('first-position-imbalance'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        rules: rules(result),
        message: detailFor(result, 'sample-count-odd'),
        firstPositionCounts: result.firstPositionCounts,
    };
});

record('A1-02', 'sampling', 'samples=7 fails closed', 'SampleBalanceError, rule sample-count-odd, exit 3', () => {
    const orders = abba(7);
    const result = validateSampleContract({ samples: 7, declaredOrders: orders, executedOrders: orders }, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'SampleBalanceError' &&
            result.exitCode === CONTRACT_EXIT_CODES.sampleBalance &&
            rules(result).includes('sample-count-odd'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        rules: rules(result),
        message: detailFor(result, 'sample-count-odd'),
        firstPositionCounts: result.firstPositionCounts,
    };
});

record('A1-03', 'sampling', 'samples=8 balanced passes', 'ok=true, 4 qjs-first and 4 zjs-first, exit 0', () => {
    const orders = abba(8);
    const result = validateSampleContract({ samples: 8, declaredOrders: orders, executedOrders: orders }, policy);
    return {
        pass:
            result.ok === true &&
            result.exitCode === CONTRACT_EXIT_CODES.ok &&
            result.firstPositionCounts.qjs === 4 &&
            result.firstPositionCounts.zjs === 4 &&
            result.positionCounts[0].qjs === 4 &&
            result.positionCounts[1].qjs === 4,
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        firstPositionCounts: result.firstPositionCounts,
        positionCounts: result.positionCounts,
    };
});

record(
    'A1-04',
    'sampling',
    'artifact claims a balanced order but execution was not balanced',
    'SampleBalanceError, rule declared-order-execution-mismatch',
    () => {
        const declared = abba(8);
        const executed = abba(8).map(() => ['qjs', 'zjs']); // every round actually ran qjs first
        const result = validateSampleContract({ samples: 8, declaredOrders: declared, executedOrders: executed }, policy);
        return {
            pass:
                result.ok === false &&
                result.errorClass === 'SampleBalanceError' &&
                rules(result).includes('declared-order-execution-mismatch') &&
                rules(result).includes('first-position-imbalance'),
            errorClass: result.errorClass,
            exitCode: result.exitCode,
            rules: rules(result),
            message: detailFor(result, 'declared-order-execution-mismatch'),
            firstPositionCounts: result.firstPositionCounts,
        };
    },
);

record('A1-05', 'sampling', 'a treatment vanishes mid-run', 'SampleBalanceError, rule treatment-missing', () => {
    const declared = abba(8);
    const executed = abba(8);
    executed[4] = ['zjs']; // qjs never completed in round 4
    const result = validateSampleContract({ samples: 8, declaredOrders: declared, executedOrders: executed }, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'SampleBalanceError' &&
            rules(result).includes('treatment-missing') &&
            result.violations.find((v) => v.rule === 'treatment-missing').rounds[0].missing[0] === 'qjs',
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        rules: rules(result),
        message: detailFor(result, 'treatment-missing'),
    };
});

record('A1-06', 'sampling', 'odd warmup fails closed in formal mode', 'SampleBalanceError, rule warmup-odd', () => {
    const result = validateWarmupContract(5, policy);
    return {
        pass: result.ok === false && result.errorClass === 'SampleBalanceError' && rules(result).includes('warmup-odd'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'warmup-odd'),
    };
});

record('A1-07', 'sampling', 'even warmup passes', 'ok=true', () => {
    const result = validateWarmupContract(4, policy);
    return { pass: result.ok === true, violations: result.violations };
});

// ---------------------------------------------------------------------------
// A2 - affinity attestation
// ---------------------------------------------------------------------------

const pinned = { mask: '19', cpus: [19] };
const unpinned = { mask: '0-19', cpus: Array.from({ length: 20 }, (_, i) => i) };
const pmu19 = { name: 'armv8_pmuv3_1', cpus: [5, 6, 7, 8, 9, 15, 16, 17, 18, 19] };
const goodChildren = [
    { treatment: 'qjs', phase: 'pre', pid: 1001, mask: '19', cpus: [19] },
    { treatment: 'zjs', phase: 'pre', pid: 1002, mask: '19', cpus: [19] },
    { treatment: 'qjs', phase: 'post', pid: 1003, mask: '19', cpus: [19] },
    { treatment: 'zjs', phase: 'post', pid: 1004, mask: '19', cpus: [19] },
];

record('A2-01', 'affinity', 'fully pinned collector and children pass', 'ok=true, exit 0', () => {
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: pinned, children: goodChildren, pmu: pmu19 },
        policy,
    );
    return { pass: result.ok === true, violations: result.violations };
});

record(
    'A2-02',
    'affinity',
    'runner allowed-list 0-19 is not pinning even though it contains 19',
    'AffinityAttestationError, rule collector-not-pinned, exit 4',
    () => {
        const result = validateAffinityAttestation(
            { requestedCpu: 19, collectorStart: unpinned, collectorEnd: unpinned, children: goodChildren, pmu: pmu19 },
            policy,
        );
        return {
            pass:
                result.ok === false &&
                result.errorClass === 'AffinityAttestationError' &&
                result.exitCode === CONTRACT_EXIT_CODES.affinityAttestation &&
                rules(result).includes('collector-not-pinned'),
            errorClass: result.errorClass,
            exitCode: result.exitCode,
            rules: rules(result),
            message: detailFor(result, 'collector-not-pinned'),
        };
    },
);

record('A2-03', 'affinity', 'a measured child escapes the pin', 'AffinityAttestationError, rule child-not-pinned', () => {
    const children = goodChildren.map((child) =>
        child.treatment === 'zjs' && child.phase === 'pre' ? { ...child, mask: '0-19', cpus: unpinned.cpus } : child,
    );
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: pinned, children, pmu: pmu19 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('child-not-pinned'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        rules: rules(result),
        message: detailFor(result, 'child-not-pinned'),
    };
});

record('A2-04', 'affinity', 'a child is re-pinned between pre and post', 'AffinityAttestationError, rules child-escaped + child-affinity-changed', () => {
    const children = goodChildren.map((child) =>
        child.treatment === 'qjs' && child.phase === 'post' ? { ...child, mask: '18', cpus: [18] } : child,
    );
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: pinned, children, pmu: pmu19 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('child-escaped') && rules(result).includes('child-affinity-changed'),
        errorClass: result.errorClass,
        rules: rules(result),
        message: detailFor(result, 'child-affinity-changed'),
    };
});

record('A2-05', 'affinity', 'requested CPU is outside the allowed set', 'AffinityAttestationError, rule requested-cpu-not-in-allowed-set', () => {
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: { mask: '0-3', cpus: [0, 1, 2, 3] }, collectorEnd: { mask: '0-3', cpus: [0, 1, 2, 3] }, children: goodChildren, pmu: pmu19 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('requested-cpu-not-in-allowed-set'),
        rules: rules(result),
        message: detailFor(result, 'requested-cpu-not-in-allowed-set'),
    };
});

record('A2-06', 'affinity', 'collector affinity changes during the run', 'AffinityAttestationError, rule collector-affinity-changed', () => {
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: { mask: '18-19', cpus: [18, 19] }, children: goodChildren, pmu: pmu19 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('collector-affinity-changed'),
        rules: rules(result),
        message: detailFor(result, 'collector-affinity-changed'),
    };
});

record('A2-07', 'affinity', 'PMU identity cannot be confirmed', 'AffinityAttestationError, rule pmu-identity-unconfirmed', () => {
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: pinned, children: goodChildren, pmu: { name: null, cpus: null } },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('pmu-identity-unconfirmed'),
        rules: rules(result),
        message: detailFor(result, 'pmu-identity-unconfirmed'),
    };
});

record('A2-08', 'affinity', 'missing child attestation', 'AffinityAttestationError, rule child-attestation-missing', () => {
    const result = validateAffinityAttestation(
        { requestedCpu: 19, collectorStart: pinned, collectorEnd: pinned, children: goodChildren.slice(0, 2), pmu: pmu19 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('child-attestation-missing'),
        rules: rules(result),
        message: detailFor(result, 'child-attestation-missing'),
    };
});

// ---------------------------------------------------------------------------
// A3 - startup residual resolvability
// ---------------------------------------------------------------------------

const startupQjs = { median: 0.79, p25: 0.77, p75: 0.83, avg: 0.79 };
const startupZjs = { median: 1.0, p25: 0.97, p75: 1.05, avg: 1.0 };

record('A3-01', 'startup', 'the aggregate startup-adjusted geomean is never emitted', 'startupAdjustedGeometricMean === null and headlineEligible === false', () => {
    const summary = startupAdjustedSummary();
    return {
        pass:
            summary.startupAdjustedGeometricMean === null &&
            summary.startupAdjustedDiagnosticOnly === true &&
            summary.startupAdjustedHeadlineEligible === false,
        summary,
    };
});

record('A3-02', 'startup', 'residual exactly zero yields no adjusted ratio', 'ratio null, status unresolved, reason residual-zero', () => {
    const result = classifyStartupResolvability(
        { qjs: { median: 0.79, p25: 0.78, p75: 0.8 }, zjs: { median: 1.0, p25: 0.99, p75: 1.01 }, startupQjs, startupZjs },
        policy,
    );
    return {
        pass:
            result.adjusted.ratio === null &&
            result.adjusted.status === 'unresolved' &&
            result.adjusted.unresolvedReasons.includes('residual-zero'),
        ratio: result.adjusted.ratio,
        reasons: result.adjusted.unresolvedReasons,
        resolvabilityClass: result.resolvabilityClass,
    };
});

record('A3-03', 'startup', 'negative residual yields no adjusted ratio', 'ratio null, reason residual-negative', () => {
    const result = classifyStartupResolvability(
        { qjs: { median: 0.7, p25: 0.69, p75: 0.71 }, zjs: { median: 0.9, p25: 0.89, p75: 0.91 }, startupQjs, startupZjs },
        policy,
    );
    return {
        pass: result.adjusted.ratio === null && result.adjusted.unresolvedReasons.includes('residual-negative'),
        ratio: result.adjusted.ratio,
        reasons: result.adjusted.unresolvedReasons,
    };
});

record('A3-04', 'startup', 'residual inside the noise band yields no adjusted ratio', 'ratio null, reason residual-below-startup-iqr', () => {
    // qjs residual 0.03 ms, below the 0.06 ms startup IQR and below the 0.05 ms
    // minimum time resolution. This is the `weak_map_set = 10.106` shape.
    const result = classifyStartupResolvability(
        { qjs: { median: 0.82, p25: 0.8, p75: 0.86 }, zjs: { median: 1.31, p25: 1.28, p75: 1.36 }, startupQjs, startupZjs },
        policy,
    );
    return {
        pass:
            result.adjusted.ratio === null &&
            result.adjusted.unresolvedReasons.includes('residual-below-startup-iqr') &&
            result.adjusted.unresolvedReasons.includes('residual-below-min-time-resolution'),
        ratio: result.adjusted.ratio,
        reasons: result.adjusted.unresolvedReasons,
        resolvabilityClass: result.resolvabilityClass,
    };
});

record('A3-05', 'startup', 'a tampered (inflated) startup baseline cannot manufacture a large ratio', 'ratio null even though the naive quotient would be 10.3', () => {
    const caseQjs = { median: 0.82, p25: 0.8, p75: 0.86 };
    const caseZjs = { median: 1.31, p25: 1.28, p75: 1.36 };
    const tampered = { median: 0.7995, p25: 0.799, p75: 0.8 };
    const naive = (caseZjs.median - startupZjs.median) / (caseQjs.median - tampered.median);
    const result = classifyStartupResolvability(
        { qjs: caseQjs, zjs: caseZjs, startupQjs: tampered, startupZjs },
        policy,
    );
    return {
        pass: result.adjusted.ratio === null && naive > 5,
        naiveRatio: naive,
        ratio: result.adjusted.ratio,
        reasons: result.adjusted.unresolvedReasons,
    };
});

record('A3-06', 'startup', 'an execution-dominant case resolves and is classified', 'class execution-dominant, ratio finite', () => {
    const result = classifyStartupResolvability(
        {
            qjs: { median: 18.5, p25: 18.4, p75: 18.7 },
            zjs: { median: 23.0, p25: 22.8, p75: 23.3 },
            startupQjs,
            startupZjs,
        },
        policy,
    );
    return {
        pass:
            result.resolvabilityClass === 'execution-dominant' &&
            Number.isFinite(result.adjusted.ratio) &&
            result.adjusted.status === 'resolved' &&
            result.adjusted.headlineEligible === false,
        resolvabilityClass: result.resolvabilityClass,
        ratio: result.adjusted.ratio,
        startupShareQjs: result.startupShareQjs,
    };
});

record('A3-07', 'startup', 'class boundaries follow the measured startup share', 'partially-resolvable at 33%, startup-dominated at 79%', () => {
    const partial = classifyStartupResolvability(
        { qjs: { median: 2.4, p25: 2.35, p75: 2.45 }, zjs: { median: 3.0, p25: 2.95, p75: 3.06 }, startupQjs, startupZjs },
        policy,
    );
    const dominated = classifyStartupResolvability(
        { qjs: { median: 1.0, p25: 0.98, p75: 1.02 }, zjs: { median: 1.3, p25: 1.28, p75: 1.33 }, startupQjs, startupZjs },
        policy,
    );
    return {
        pass: partial.resolvabilityClass === 'partially-resolvable' && dominated.resolvabilityClass === 'startup-dominated',
        partial: { class: partial.resolvabilityClass, share: partial.startupShareQjs },
        dominated: { class: dominated.resolvabilityClass, share: dominated.startupShareQjs },
    };
});

// ---------------------------------------------------------------------------
// A4 - provenance completeness and the artifact-policy ban
// ---------------------------------------------------------------------------

function completeArtifact() {
    return {
        meta: {
            zjs: { commit: 'a'.repeat(40), sha256: 'b'.repeat(64), binary: '/tmp/zjs', dirty: false },
            qjs: { commit: '04be246001599f5995fa2f2d8c91a0f198d3f34c', version: '2026-06-04', sha256: 'c'.repeat(64), binary: '/tmp/qjs', dirty: false },
            toolRepoCommit: { commit: 'd'.repeat(40), dirty: false },
            host: {
                kernel: '6.17.0-1014-nvidia',
                cpuModel: 'Cortex-X925 / Cortex-A725',
                pinnedCpu: 19,
                affinityMask: '19',
                pmuIdentity: { name: 'armv8_pmuv3_1', cpus: [19] },
            },
            sampling: { iters: 8, warmup: 4, samples: 8, timed: { sampleOrders: abba(8).map((o) => o.join('->')) } },
            startupBaselineIdentity: { scriptSha256: 'e'.repeat(64), generation: 'gen-1' },
            lock: { path: '/tmp/zjs-host-heavy.lock', mode: 'exclusive' },
            environment: { ZIG_GLOBAL_CACHE_DIR: '/x', TMPDIR: '/y', ZJS_REPO_ROOT: '/z' },
            caseSources: { int_sum: { sourcePath: '/tmp/int_sum.js', sourceSha256: 'f'.repeat(64) } },
        },
        cases: [{ name: 'int_sum', status: 'ok', sourceSha256: 'f'.repeat(64), sourcePath: '/tmp/int_sum.js' }],
    };
}

record('A4-01', 'provenance', 'a complete artifact passes', 'ok=true, no missing fields', () => {
    const result = validateProvenance(completeArtifact(), policy);
    return { pass: result.ok === true, missing: result.missing, caseMissing: result.caseMissing };
});

record('A4-02', 'provenance', 'a missing binary SHA-256 fails closed', 'ProvenanceIncompleteError, exit 5, meta.zjs.sha256 listed', () => {
    const artifact = completeArtifact();
    delete artifact.meta.zjs.sha256;
    const result = validateProvenance(artifact, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'ProvenanceIncompleteError' &&
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            result.missing.includes('meta.zjs.sha256'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        missing: result.missing,
        message: detailFor(result, 'provenance-field-missing'),
    };
});

record('A4-03', 'provenance', 'a missing per-case source SHA fails closed', 'rule case-provenance-field-missing', () => {
    const artifact = completeArtifact();
    delete artifact.cases[0].sourceSha256;
    const result = validateProvenance(artifact, policy);
    return {
        pass: result.ok === false && rules(result).includes('case-provenance-field-missing'),
        caseMissing: result.caseMissing,
        message: detailFor(result, 'case-provenance-field-missing'),
    };
});

record('A4-04', 'provenance', 'missing lock and environment provenance fails closed', 'meta.lock.mode and TMPDIR listed', () => {
    const artifact = completeArtifact();
    delete artifact.meta.lock.mode;
    delete artifact.meta.environment.TMPDIR;
    const result = validateProvenance(artifact, policy);
    return {
        pass:
            result.ok === false &&
            result.missing.includes('meta.lock.mode') &&
            result.missing.includes('meta.environment.TMPDIR'),
        missing: result.missing,
    };
});

record('A4-05', 'provenance', 'an artifact that supplies its own thresholds is rejected', 'ArtifactPolicyOverrideError, exit 6', () => {
    const artifact = completeArtifact();
    artifact.startup = { minTimeResolutionMs: 0.0 };
    const result = assertNoSelfSuppliedPolicy(artifact, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'ArtifactPolicyOverrideError' &&
            result.exitCode === CONTRACT_EXIT_CODES.artifactPolicyOverride &&
            rules(result).includes('artifact-supplied-policy'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'artifact-supplied-policy'),
    };
});

record('A4-06', 'provenance', 'an artifact may reference the policy but not restate it', 'policyRef with id/version/sha passes; extra keys rejected', () => {
    const ok = completeArtifact();
    ok.policyRef = { policy_id: policy.policy_id, policy_version: policy.policy_version, sha256: 'a'.repeat(64) };
    const okResult = assertNoSelfSuppliedPolicy(ok, policy);
    const bad = completeArtifact();
    bad.policyRef = { policy_id: policy.policy_id, minimumSamples: 1 };
    const badResult = assertNoSelfSuppliedPolicy(bad, policy);
    return {
        pass: okResult.ok === true && badResult.ok === false && rules(badResult).includes('artifact-supplied-policy'),
        okViolations: okResult.violations,
        badMessage: detailFor(badResult, 'artifact-supplied-policy'),
    };
});

record('A4-06b', 'provenance', 'a case source SHA that disagrees with the suite table fails closed', 'rule case-source-sha-mismatch', () => {
    const artifact = completeArtifact();
    artifact.cases[0].sourceSha256 = '0'.repeat(64);
    const result = validateProvenance(artifact, policy);
    return {
        pass: result.ok === false && rules(result).includes('case-source-sha-mismatch'),
        message: detailFor(result, 'case-source-sha-mismatch'),
    };
});

record('A4-07', 'provenance', 'a dirty worktree fails closed in formal mode', 'ProvenanceIncompleteError, rule dirty-worktree', () => {
    const artifact = completeArtifact();
    artifact.meta.toolRepoCommit.dirty = true;
    const result = validateWorktreeCleanliness(artifact);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'ProvenanceIncompleteError' &&
            result.exitCode === CONTRACT_EXIT_CODES.provenanceIncomplete &&
            rules(result).includes('dirty-worktree'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'dirty-worktree'),
    };
});

record('A4-08', 'provenance', 'a startup baseline from another generation fails closed', 'rule generation-mismatch', () => {
    const artifact = completeArtifact();
    artifact.meta.startupBaselineIdentity.generation = 'phase-6-closeout';
    artifact.cases[0].generation = 'gen-1';
    const result = validateGenerationCoherence(artifact);
    return {
        pass: result.ok === false && rules(result).includes('generation-mismatch'),
        message: detailFor(result, 'generation-mismatch'),
    };
});

record('A4-09', 'provenance', 'a coherent generation passes', 'ok=true when case and baseline share a generation', () => {
    const artifact = completeArtifact();
    artifact.cases[0].generation = 'gen-1';
    const result = validateGenerationCoherence(artifact);
    return { pass: result.ok === true, violations: result.violations };
});

// ---------------------------------------------------------------------------
// A5 - session schema
// ---------------------------------------------------------------------------

record('A5-01', 'sessions', 'session mode is off by default and the legacy path is unchanged', 'enabled=false, legacyPathUnchanged=true, schemaVersion=2', () => {
    const block = { schemaVersion: policy.sessions.schemaVersion, enabled: false, sessions: 1, interleaved: false, headlineEligible: false, legacyPathUnchanged: true, mixedWithLegacySamples: false };
    const result = validateSessionSchema(block, policy);
    return {
        pass: result.ok === true && policy.sessions.defaultSessions === 1 && policy.sessions.defaultInterleaved === false,
        defaults: { sessions: policy.sessions.defaultSessions, interleaved: policy.sessions.defaultInterleaved },
        schemaVersion: policy.sessions.schemaVersion,
    };
});

record('A5-02', 'sessions', 'an unversioned session block is rejected', 'SessionSchemaError, rule session-schema-version, exit 8', () => {
    const result = validateSessionSchema({ schemaVersion: 1, enabled: true, sessions: 3, headlineEligible: false }, policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'SessionSchemaError' &&
            result.exitCode === CONTRACT_EXIT_CODES.sessionSchema &&
            rules(result).includes('session-schema-version'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'session-schema-version'),
    };
});

record('A5-03', 'sessions', 'session results may not be headline eligible', 'rule session-headline-eligible', () => {
    const result = validateSessionSchema({ schemaVersion: 2, enabled: true, sessions: 3, headlineEligible: true }, policy);
    return {
        pass: result.ok === false && rules(result).includes('session-headline-eligible'),
        message: detailFor(result, 'session-headline-eligible'),
    };
});

record('A5-04', 'sessions', 'session samples may not be mixed into the legacy pool', 'rule session-legacy-sample-mixing', () => {
    const result = validateSessionSchema(
        { schemaVersion: 2, enabled: true, sessions: 3, headlineEligible: false, mixedWithLegacySamples: true },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('session-legacy-sample-mixing'),
        message: detailFor(result, 'session-legacy-sample-mixing'),
    };
});

// ---------------------------------------------------------------------------
// A6 - P7-42 contracts, made automatically checkable
// ---------------------------------------------------------------------------

record('A6-01', 'attribution', 'bare file:line stage attribution is rejected', 'AttributionScopeError, rule bare-file-line-attribution, exit 9', () => {
    const result = validateStageAttribution([{ stage: 'callback-return', scope: 'symbol', key: 'quickjs.c:9840' }], policy);
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'AttributionScopeError' &&
            result.exitCode === CONTRACT_EXIT_CODES.attributionScope &&
            rules(result).includes('bare-file-line-attribution'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'bare-file-line-attribution'),
    };
});

record('A6-02', 'attribution', 'a scoped stage attribution passes', 'ok=true for symbol/callChain/addressRange scopes', () => {
    const result = validateStageAttribution(
        [
            { stage: 'driver-reentry', scope: 'symbol', key: 'vm.zig:1180', symbol: 'Vm.next' },
            { stage: 'callback-return', scope: 'callChain', key: 'callback', callChain: ['js_array_map', 'JS_CallInternal', 'Vm.next'] },
            { stage: 'return-path', scope: 'addressRange', key: 'op_return', addressRange: { start: '0x4a1200', end: '0x4a1290' } },
        ],
        policy,
    );
    return { pass: result.ok === true, violations: result.violations };
});

record('A6-03', 'attribution', 'an unscoped stage is rejected', 'rule stage-scope-not-allowed', () => {
    const result = validateStageAttribution([{ stage: 'x', scope: 'fileLine', key: 'vm.zig:12' }], policy);
    return {
        pass: result.ok === false && rules(result).includes('stage-scope-not-allowed'),
        message: detailFor(result, 'stage-scope-not-allowed'),
    };
});

record('A6-04', 'attribution', 'perf -F is rejected for phase attribution', 'PhaseSamplingError, rule frequency-sampling-for-phase-attribution, exit 10', () => {
    const result = validatePhaseSampling(
        { argv: ['perf', 'record', '-F', '20000', '--', './zjs', 'case.js'], recordedPeriod: null, innerLoopPeriod: 100 },
        policy,
    );
    return {
        pass:
            result.ok === false &&
            result.errorClass === 'PhaseSamplingError' &&
            result.exitCode === CONTRACT_EXIT_CODES.phaseSampling &&
            rules(result).includes('frequency-sampling-for-phase-attribution'),
        errorClass: result.errorClass,
        exitCode: result.exitCode,
        message: detailFor(result, 'frequency-sampling-for-phase-attribution'),
    };
});

record('A6-05', 'attribution', 'a fixed co-prime recorded period passes', 'ok=true for period 100003 against inner loop 100', () => {
    const result = validatePhaseSampling(
        { argv: ['perf', 'record', '-e', 'cycles', '-c', '100003', '--', './zjs', 'case.js'], recordedPeriod: 100003, innerLoopPeriod: 100 },
        policy,
    );
    return { pass: result.ok === true, violations: result.violations };
});

record('A6-06', 'attribution', 'a period that shares a factor with the inner loop is rejected', 'rule phase-period-not-coprime', () => {
    const result = validatePhaseSampling(
        { argv: ['perf', 'record', '-c', '100000', '--', './zjs', 'case.js'], recordedPeriod: 100000, innerLoopPeriod: 100 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('phase-period-not-coprime'),
        message: detailFor(result, 'phase-period-not-coprime'),
    };
});

record('A6-07', 'attribution', 'an unrecorded period is rejected', 'rule phase-period-not-recorded', () => {
    const result = validatePhaseSampling(
        { argv: ['perf', 'record', '-c', '100003', '--', './zjs', 'case.js'], recordedPeriod: null, innerLoopPeriod: 100 },
        policy,
    );
    return {
        pass: result.ok === false && rules(result).includes('phase-period-not-recorded'),
        message: detailFor(result, 'phase-period-not-recorded'),
    };
});

// ---------------------------------------------------------------------------
// A7 - the same-runtime runner's own sampling defaults
//
// These spawn the real runner. Its --samples handling is rejected during
// argument parsing, before any harness is required, so these run anywhere.
// The *default* value is asserted empirically from the sentinel artifact in
// the closeout gate run rather than here, because observing it requires a
// full sampling pass.
// ---------------------------------------------------------------------------

const sameRuntimeRunner = path.resolve(
    path.dirname(new URL(import.meta.url).pathname),
    '../perf/same_runtime/run_same_runtime.js',
);

function runSameRuntime(args) {
    return spawnSync('node', [sameRuntimeRunner, ...args], { encoding: 'utf8' });
}

record('A7-01', 'sampling', 'the same-runtime runner rejects an odd --samples', 'exit 2 naming measurement contract #3', () => {
    const r = runSameRuntime(['--samples', '5']);
    const text = `${r.stderr || ''}${r.stdout || ''}`;
    return {
        pass:
            r.status === 2 &&
            /--samples must be even/.test(text) &&
            /5 is odd/.test(text) &&
            /measurement contract #3/.test(text),
        exitCode: r.status,
        message: text.trim().split('\n')[0],
    };
});

record('A7-02', 'sampling', 'the same-runtime runner rejects --samples 7 as well', 'exit 2, not special-cased to 5', () => {
    const r = runSameRuntime(['--samples', '7']);
    const text = `${r.stderr || ''}${r.stdout || ''}`;
    return {
        pass: r.status === 2 && /7 is odd/.test(text),
        exitCode: r.status,
        message: text.trim().split('\n')[0],
    };
});

record('A7-03', 'sampling', 'an odd --samples is refused rather than rounded up', 'the error text must not claim an adjustment', () => {
    const r = runSameRuntime(['--samples', '5']);
    const text = `${r.stderr || ''}${r.stdout || ''}`;
    // Rounding an odd request up to even would silently change the measurement
    // design behind the caller's back, so the contract is refusal.
    return {
        pass: r.status === 2 && !/round|adjust|using 6|coerc/i.test(text),
        exitCode: r.status,
        message: text.trim().split('\n')[0],
    };
});

record('A7-04', 'sampling', 'the documented default is even', '--help advertises an even default', () => {
    const r = runSameRuntime(['--help']);
    const text = `${r.stdout || ''}${r.stderr || ''}`;
    const m = /--samples K\s+Paired harness invocations per case, must be even \(default: (\d+)\)/.exec(text);
    return {
        pass: Boolean(m) && Number(m[1]) % 2 === 0,
        exitCode: r.status,
        message: m ? `documented default ${m[1]}` : 'usage line not found',
    };
});

// ---------------------------------------------------------------------------

const summary = {
    tool: 'zjs-measurement-contract-tests',
    policy: { policy_id: policy.policy_id, policy_version: policy.policy_version, sha256: policy.__source.sha256 },
    timestamp: new Date().toISOString(),
    total: results.length,
    passed: results.filter((r) => r.status === 'pass').length,
    failed: failures,
    exitCodeMap: CONTRACT_EXIT_CODES,
    tests: results,
};

const outputIndex = process.argv.indexOf('--output');
if (outputIndex !== -1 && process.argv[outputIndex + 1]) {
    const target = path.resolve(process.cwd(), process.argv[outputIndex + 1]);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, `${JSON.stringify(summary, null, 2)}\n`);
}
console.log(`\n${summary.passed}/${summary.total} contract tests passed`);
process.exit(failures === 0 ? 0 : 1);
