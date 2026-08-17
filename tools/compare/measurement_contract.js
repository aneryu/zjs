// Whole-process measurement contract.
//
// Every rule in this module exists because a violation of it already produced a
// wrong answer in this campaign; see tools/compare/measurement_policy.json
// for the incident register. The module is deliberately dependency-free and
// side-effect-free so the contract tests can drive it directly.
//
// The single design rule: a contract violation must be *fail closed*. A warning
// followed by a published headline is the failure mode this module removes.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export const CONTRACT_EXIT_CODES = {
    ok: 0,
    validationFailure: 1,
    usage: 2,
    sampleBalance: 3,
    affinityAttestation: 4,
    provenanceIncomplete: 5,
    artifactPolicyOverride: 6,
    startupResolution: 7,
    sessionSchema: 8,
    attributionScope: 9,
    phaseSampling: 10,
};

export class ContractError extends Error {
    constructor(message, { errorClass, exitCode, violations = [] }) {
        super(message);
        this.name = errorClass;
        this.errorClass = errorClass;
        this.exitCode = exitCode;
        this.violations = violations;
    }
}

const errorClassExit = {
    SampleBalanceError: CONTRACT_EXIT_CODES.sampleBalance,
    AffinityAttestationError: CONTRACT_EXIT_CODES.affinityAttestation,
    ProvenanceIncompleteError: CONTRACT_EXIT_CODES.provenanceIncomplete,
    ArtifactPolicyOverrideError: CONTRACT_EXIT_CODES.artifactPolicyOverride,
    StartupResolutionError: CONTRACT_EXIT_CODES.startupResolution,
    SessionSchemaError: CONTRACT_EXIT_CODES.sessionSchema,
    AttributionScopeError: CONTRACT_EXIT_CODES.attributionScope,
    PhaseSamplingError: CONTRACT_EXIT_CODES.phaseSampling,
};

export function contractError(errorClass, message, violations = []) {
    const exitCode = errorClassExit[errorClass];
    if (exitCode == null) throw new Error(`unknown contract error class: ${errorClass}`);
    return new ContractError(message, { errorClass, exitCode, violations });
}

// ---------------------------------------------------------------------------
// Policy loading. The authoritative policy lives in the repository; artifacts
// are never allowed to supply their own thresholds (contract §12).
// ---------------------------------------------------------------------------

export const POLICY_PATH = path.join(import.meta.dirname ?? path.dirname(new URL(import.meta.url).pathname), 'measurement_policy.json');

export function loadPolicy(policyPath = POLICY_PATH) {
    const raw = fs.readFileSync(policyPath);
    const policy = JSON.parse(raw.toString('utf8'));
    return {
        ...policy,
        __source: {
            path: policyPath,
            sha256: crypto.createHash('sha256').update(raw).digest('hex'),
        },
    };
}

export function policyReference(policy) {
    return {
        policy_id: policy.policy_id,
        policy_version: policy.policy_version,
        sha256: policy.__source?.sha256 ?? null,
        path: policy.__source?.path ?? null,
    };
}

// ---------------------------------------------------------------------------
// A1: sample count and order, fail closed.
// ---------------------------------------------------------------------------

function orderKey(order) {
    return Array.isArray(order) ? order.join('->') : String(order);
}

/**
 * @param {object} input
 * @param {number} input.samples          declared timed sample count
 * @param {string[][]} input.declaredOrders  the order the artifact claims it ran
 * @param {string[][]} input.executedOrders  the order actually recorded while running
 * @param {string[]} [input.treatments]
 */
export function validateSampleContract(input, policy) {
    const rules = policy.sampling;
    const treatments = input.treatments ?? rules.treatments;
    const violations = [];
    const declared = input.declaredOrders ?? [];
    const executed = input.executedOrders ?? [];

    if (!Number.isInteger(input.samples) || input.samples < rules.minimumSamples) {
        violations.push({
            rule: 'sample-count-invalid',
            detail: `samples=${input.samples} must be an integer >= ${rules.minimumSamples}`,
        });
    }
    if (rules.requireEvenSampleCount && Number.isInteger(input.samples) && input.samples % 2 !== 0) {
        violations.push({
            rule: 'sample-count-odd',
            detail: `samples=${input.samples} is odd; ABBA cannot balance an odd sample count`,
        });
    }
    if (declared.length !== input.samples) {
        violations.push({
            rule: 'declared-order-length-mismatch',
            detail: `artifact declares ${declared.length} sample orders for samples=${input.samples}`,
        });
    }
    if (executed.length !== input.samples) {
        violations.push({
            rule: 'executed-order-length-mismatch',
            detail: `execution recorded ${executed.length} sample orders for samples=${input.samples}`,
        });
    }

    if (rules.requireDeclaredOrderMatchesExecution) {
        const limit = Math.min(declared.length, executed.length);
        const mismatches = [];
        for (let i = 0; i < limit; i += 1) {
            if (orderKey(declared[i]) !== orderKey(executed[i])) {
                mismatches.push({ index: i, declared: orderKey(declared[i]), executed: orderKey(executed[i]) });
            }
        }
        if (mismatches.length !== 0) {
            violations.push({
                rule: 'declared-order-execution-mismatch',
                detail: `the artifact-declared order differs from the recorded execution at ${mismatches.length} index(es)`,
                mismatches: mismatches.slice(0, 8),
            });
        }
    }

    const firstPositionCounts = Object.fromEntries(treatments.map((t) => [t, 0]));
    const positionCounts = treatments.map(() => Object.fromEntries(treatments.map((t) => [t, 0])));
    const incomplete = [];
    for (let i = 0; i < executed.length; i += 1) {
        const round = Array.isArray(executed[i]) ? executed[i] : [];
        const present = new Set(round);
        const missing = treatments.filter((t) => !present.has(t));
        if (round.length !== treatments.length || missing.length !== 0) {
            incomplete.push({ index: i, executed: orderKey(round), missing });
            continue;
        }
        firstPositionCounts[round[0]] += 1;
        for (let position = 0; position < round.length; position += 1) {
            positionCounts[position][round[position]] += 1;
        }
    }
    if (incomplete.length !== 0) {
        violations.push({
            rule: 'treatment-missing',
            detail: `${incomplete.length} round(s) did not execute every treatment`,
            rounds: incomplete.slice(0, 8),
        });
    }

    if (rules.requireBalancedFirstPosition) {
        const counts = treatments.map((t) => firstPositionCounts[t]);
        if (new Set(counts).size !== 1) {
            violations.push({
                rule: 'first-position-imbalance',
                detail: `first-position counts are ${JSON.stringify(firstPositionCounts)}; every treatment must lead equally often`,
            });
        }
    }
    if (rules.requireEveryTreatmentInEveryPosition) {
        const expected = executed.length === 0 ? 0 : (executed.length - incomplete.length) / treatments.length;
        for (let position = 0; position < positionCounts.length; position += 1) {
            for (const treatment of treatments) {
                if (positionCounts[position][treatment] !== expected) {
                    violations.push({
                        rule: 'position-imbalance',
                        detail:
                            `treatment ${treatment} appears ${positionCounts[position][treatment]} time(s) in position ` +
                            `${position}, expected ${expected}`,
                    });
                }
            }
        }
    }

    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'SampleBalanceError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.sampleBalance,
        samples: input.samples,
        treatments,
        firstPositionCounts,
        positionCounts,
        declaredOrders: declared.map(orderKey),
        executedOrders: executed.map(orderKey),
        violations,
    };
}

export function validateWarmupContract(warmup, policy) {
    const violations = [];
    if (!policy.sampling.requireEvenWarmupInFormalMode) return { ok: true, violations };
    if (!Number.isInteger(warmup) || warmup < 0) {
        violations.push({ rule: 'warmup-invalid', detail: `warmup=${warmup} must be a non-negative integer` });
    } else if (warmup % 2 !== 0) {
        violations.push({
            rule: 'warmup-odd',
            detail: `warmup=${warmup} is odd; the warmup rounds would themselves be order-imbalanced`,
        });
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'SampleBalanceError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.sampleBalance,
        violations,
    };
}

// ---------------------------------------------------------------------------
// A2: CPU affinity, fail closed.
// ---------------------------------------------------------------------------

export function parseCpuList(mask) {
    if (mask == null) return null;
    const cpus = [];
    for (const segment of String(mask).split(',')) {
        const trimmed = segment.trim();
        if (!trimmed) continue;
        const range = trimmed.match(/^(\d+)-(\d+)$/);
        if (range) {
            const first = Number(range[1]);
            const last = Number(range[2]);
            if (last < first) return null;
            for (let cpu = first; cpu <= last; cpu += 1) cpus.push(cpu);
            continue;
        }
        if (!/^\d+$/.test(trimmed)) return null;
        cpus.push(Number(trimmed));
    }
    return [...new Set(cpus)].sort((a, b) => a - b);
}

function isExactlyCpu(cpus, cpu) {
    return Array.isArray(cpus) && cpus.length === 1 && cpus[0] === cpu;
}

/**
 * @param {object} input
 * @param {number} input.requestedCpu
 * @param {{mask: string|null, cpus: number[]|null}} input.collectorStart
 * @param {{mask: string|null, cpus: number[]|null}} input.collectorEnd
 * @param {Array<{treatment: string, phase: 'pre'|'post', pid: number|null, mask: string|null, cpus: number[]|null}>} input.children
 * @param {{name: string|null, cpus: number[]|null}} input.pmu
 */
export function validateAffinityAttestation(input, policy) {
    const rules = policy.affinity;
    const violations = [];
    const cpu = input.requestedCpu;

    if (!Number.isInteger(cpu)) {
        violations.push({ rule: 'requested-cpu-missing', detail: 'formal sampling requires an explicit --cpu N' });
    }

    const collectorStart = input.collectorStart ?? {};
    const collectorEnd = input.collectorEnd ?? {};
    if (rules.requireCollectorAttestation) {
        if (!Array.isArray(collectorStart.cpus) || collectorStart.cpus.length === 0) {
            violations.push({
                rule: 'collector-affinity-unreadable',
                detail: `collector Cpus_allowed_list=${collectorStart.mask ?? 'unavailable'} could not be parsed`,
            });
        } else if (Number.isInteger(cpu) && !collectorStart.cpus.includes(cpu)) {
            violations.push({
                rule: 'requested-cpu-not-in-allowed-set',
                detail: `requested CPU ${cpu} is not in the collector allowed set ${collectorStart.mask}`,
            });
        } else if (rules.requireExactCpuSet && !isExactlyCpu(collectorStart.cpus, cpu)) {
            violations.push({
                rule: 'collector-not-pinned',
                detail:
                    `collector Cpus_allowed_list=${collectorStart.mask} is not exactly {${cpu}}; ` +
                    'an allowed-list that merely contains the CPU is not pinning',
            });
        }
        const startKey = (collectorStart.cpus ?? []).join(',');
        const endKey = (collectorEnd.cpus ?? []).join(',');
        if (startKey !== endKey) {
            violations.push({
                rule: 'collector-affinity-changed',
                detail: `collector affinity moved from {${startKey}} to {${endKey}} during the run`,
            });
        }
    }

    if (rules.requireChildAttestation) {
        const children = input.children ?? [];
        const treatments = policy.sampling.treatments;
        const phases = rules.requireChildAttestationAtEnd ? ['pre', 'post'] : ['pre'];
        for (const treatment of treatments) {
            for (const phase of phases) {
                const record = children.find((c) => c.treatment === treatment && c.phase === phase);
                if (!record) {
                    violations.push({
                        rule: 'child-attestation-missing',
                        detail: `no ${phase}-run affinity attestation for the measured ${treatment} child`,
                    });
                    continue;
                }
                if (record.pid == null) {
                    violations.push({
                        rule: 'child-pid-unavailable',
                        detail: `${treatment} ${phase} attestation carries no real child PID`,
                    });
                    continue;
                }
                if (!isExactlyCpu(record.cpus, cpu)) {
                    violations.push({
                        rule: phase === 'post' ? 'child-escaped' : 'child-not-pinned',
                        detail:
                            `measured ${treatment} child pid=${record.pid} (${phase}) has ` +
                            `Cpus_allowed_list=${record.mask ?? 'unavailable'}, expected exactly {${cpu}}`,
                    });
                }
            }
        }
        // A child that changes affinity between pre and post is a re-pinned child.
        for (const treatment of treatments) {
            const pre = children.find((c) => c.treatment === treatment && c.phase === 'pre');
            const post = children.find((c) => c.treatment === treatment && c.phase === 'post');
            if (pre && post && (pre.cpus ?? []).join(',') !== (post.cpus ?? []).join(',')) {
                violations.push({
                    rule: 'child-affinity-changed',
                    detail:
                        `measured ${treatment} child affinity moved from {${(pre.cpus ?? []).join(',')}} to ` +
                        `{${(post.cpus ?? []).join(',')}} across the run`,
                });
            }
        }
    }

    if (rules.requirePmuIdentity) {
        const pmu = input.pmu ?? {};
        if (!pmu.name) {
            violations.push({ rule: 'pmu-identity-unconfirmed', detail: 'the PMU serving the pinned CPU could not be identified' });
        } else if (Number.isInteger(cpu) && Array.isArray(pmu.cpus) && !pmu.cpus.includes(cpu)) {
            violations.push({
                rule: 'pmu-identity-mismatch',
                detail: `PMU ${pmu.name} serves CPUs {${pmu.cpus.join(',')}}, which does not include ${cpu}`,
            });
        }
    }

    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'AffinityAttestationError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.affinityAttestation,
        requestedCpu: cpu,
        collectorStart,
        collectorEnd,
        children: input.children ?? [],
        pmu: input.pmu ?? null,
        violations,
    };
}

// ---------------------------------------------------------------------------
// A3: startup residual resolvability. `startupAdjusted` is diagnostic only.
// ---------------------------------------------------------------------------

export function iqr(stats) {
    if (!stats || !Number.isFinite(stats.p25) || !Number.isFinite(stats.p75)) return null;
    return stats.p75 - stats.p25;
}

/**
 * Resolve one engine's startup residual.
 * Returns { residualMs, resolved, reasons[] }.
 */
export function resolveStartupResidual(caseStats, startupStats, policy) {
    const rules = policy.startup;
    const reasons = [];
    if (!caseStats || !startupStats || !Number.isFinite(caseStats.median) || !Number.isFinite(startupStats.median)) {
        return { residualMs: null, resolved: false, reasons: ['missing-statistics'] };
    }
    const residual = caseStats.median - startupStats.median;
    if (!(residual > 0)) reasons.push(residual === 0 ? 'residual-zero' : 'residual-negative');
    const startupIqr = iqr(startupStats);
    const caseIqr = iqr(caseStats);
    if (rules.requireResidualAboveStartupIqr && startupIqr != null && residual < startupIqr) {
        reasons.push('residual-below-startup-iqr');
    }
    if (rules.requireResidualAboveCaseIqr && caseIqr != null && residual < caseIqr) {
        reasons.push('residual-below-case-iqr');
    }
    if (residual < rules.minTimeResolutionMs) reasons.push('residual-below-min-time-resolution');
    return {
        residualMs: residual,
        startupIqrMs: startupIqr,
        caseIqrMs: caseIqr,
        minTimeResolutionMs: rules.minTimeResolutionMs,
        resolved: reasons.length === 0,
        reasons,
    };
}

/**
 * Classify a case by *currently measured* startup share and compute a per-case
 * adjusted ratio only when both engines resolve.
 */
export function classifyStartupResolvability(input, policy) {
    const rules = policy.startup;
    const qjs = resolveStartupResidual(input.qjs, input.startupQjs, policy);
    const zjs = resolveStartupResidual(input.zjs, input.startupZjs, policy);

    const shareOf = (caseStats, startupStats) =>
        caseStats && startupStats && Number.isFinite(caseStats.median) && caseStats.median > 0
            ? startupStats.median / caseStats.median
            : null;
    const startupShareQjs = shareOf(input.qjs, input.startupQjs);
    const startupShareZjs = shareOf(input.zjs, input.startupZjs);
    const classifierShare = rules.classifierEngine === 'zjs' ? startupShareZjs : startupShareQjs;

    let resolvabilityClass = 'unknown';
    if (Number.isFinite(classifierShare)) {
        if (classifierShare <= rules.executionDominantMaxStartupShare) resolvabilityClass = 'execution-dominant';
        else if (classifierShare <= rules.partiallyResolvableMaxStartupShare) resolvabilityClass = 'partially-resolvable';
        else resolvabilityClass = 'startup-dominated';
    }

    const resolved = qjs.resolved && zjs.resolved;
    // Never divide by a near-zero denominator: the ratio only exists when the
    // qjs residual itself cleared every resolution test.
    const ratio = resolved && qjs.residualMs > 0 ? zjs.residualMs / qjs.residualMs : null;

    return {
        resolvabilityClass,
        startupShareQjs,
        startupShareZjs,
        classifierEngine: rules.classifierEngine,
        residual: { qjs, zjs },
        adjusted: {
            ratio,
            status: resolved ? 'resolved' : 'unresolved',
            diagnosticOnly: true,
            headlineEligible: false,
            unresolvedReasons: resolved ? [] : [...new Set([...qjs.reasons, ...zjs.reasons])],
        },
    };
}

export function startupAdjustedSummary() {
    // Codified demotion: the schema field survives, the number does not.
    return {
        startupAdjustedGeometricMean: null,
        startupAdjustedDiagnosticOnly: true,
        startupAdjustedHeadlineEligible: false,
        startupAdjustedGeometricMeanIsArbitration: false,
        startupAdjustedVoidReason:
            'P7-20/P7-70: with this suite composition the majority of denominators are at or below the noise band; ' +
            'unresolved cases are never aggregated and the aggregate is therefore not emitted',
    };
}

// ---------------------------------------------------------------------------
// A4: provenance completeness, and the ban on artifact-supplied thresholds.
// ---------------------------------------------------------------------------

export function readPath(object, dottedPath) {
    let cursor = object;
    for (const segment of dottedPath.split('.')) {
        if (cursor == null || typeof cursor !== 'object') return undefined;
        cursor = cursor[segment];
    }
    return cursor;
}

function isPresent(value) {
    if (value === undefined || value === null) return false;
    if (typeof value === 'string') return value.trim().length !== 0;
    if (Array.isArray(value)) return value.length !== 0;
    if (typeof value === 'object') return Object.keys(value).length !== 0;
    return true;
}

export function validateProvenance(artifact, policy) {
    const violations = [];
    const missing = [];
    for (const field of policy.provenance.requiredFields) {
        const value = readPath(artifact, field);
        // `dirty` is a boolean whose false value is meaningful.
        if (typeof value === 'boolean') continue;
        if (!isPresent(value)) missing.push(field);
    }
    if (missing.length !== 0) {
        violations.push({
            rule: 'provenance-field-missing',
            detail: `missing required provenance field(s): ${missing.join(', ')}`,
            missing,
        });
    }

    const cases = Array.isArray(artifact?.cases) ? artifact.cases : [];
    const caseMissing = [];
    for (const row of cases) {
        if (row.status !== 'ok') continue;
        for (const field of policy.provenance.requiredPerCaseFields) {
            if (!isPresent(row[field])) caseMissing.push(`${row.name}.${field}`);
        }
    }
    if (caseMissing.length !== 0) {
        violations.push({
            rule: 'case-provenance-field-missing',
            detail: `missing required per-case provenance field(s): ${caseMissing.slice(0, 8).join(', ')}`,
            missing: caseMissing,
        });
    }

    // The per-case SHA and the suite-level case-source table must agree; a case
    // whose recorded source hash does not match what the suite says was written
    // means the measured script is not the script the artifact claims.
    const table = readPath(artifact, 'meta.caseSources') ?? {};
    const shaMismatches = [];
    for (const row of cases) {
        if (row.status !== 'ok') continue;
        const declared = table[row.name]?.sourceSha256 ?? null;
        if (declared != null && row.sourceSha256 != null && declared !== row.sourceSha256) {
            shaMismatches.push({ case: row.name, caseSha: row.sourceSha256, tableSha: declared });
        }
        if (declared == null) shaMismatches.push({ case: row.name, caseSha: row.sourceSha256, tableSha: null });
    }
    if (shaMismatches.length !== 0) {
        violations.push({
            rule: 'case-source-sha-mismatch',
            detail:
                `case source SHA-256 disagreement for ${shaMismatches.length} case(s), first: ` +
                `${shaMismatches[0].case} row=${shaMismatches[0].caseSha} table=${shaMismatches[0].tableSha}`,
            mismatches: shaMismatches.slice(0, 8),
        });
    }

    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'ProvenanceIncompleteError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.provenanceIncomplete,
        missing,
        caseMissing,
        violations,
    };
}

// A formal snapshot may not be produced from a dirty tree: the commit recorded
// in the artifact would then not describe the binary that was measured.
export function validateWorktreeCleanliness(artifact) {
    const violations = [];
    for (const [label, value] of [
        ['toolRepoCommit', readPath(artifact, 'meta.toolRepoCommit.dirty')],
        ['zjs', readPath(artifact, 'meta.zjs.dirty')],
        ['qjs', readPath(artifact, 'meta.qjs.dirty')],
    ]) {
        if (value === true) {
            violations.push({
                rule: 'dirty-worktree',
                detail: `${label} repository was dirty at measurement time; the recorded commit does not describe the measured binary`,
            });
        } else if (value == null) {
            violations.push({ rule: 'dirty-state-unknown', detail: `${label} dirty state could not be determined` });
        }
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'ProvenanceIncompleteError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.provenanceIncomplete,
        violations,
    };
}

// The startup baseline and the cases must come from the same measurement
// generation; reusing an archived baseline is what voided the Phase 6 numbers.
export function validateGenerationCoherence(artifact) {
    const violations = [];
    const baselineGeneration = readPath(artifact, 'meta.startupBaselineIdentity.generation') ?? null;
    if (!baselineGeneration) {
        violations.push({ rule: 'startup-generation-missing', detail: 'the startup baseline carries no generation id' });
    }
    for (const row of artifact?.cases ?? []) {
        if (row.status !== 'ok') continue;
        if (row.generation !== baselineGeneration) {
            violations.push({
                rule: 'generation-mismatch',
                detail:
                    `case ${row.name} generation=${row.generation} differs from the startup baseline ` +
                    `generation=${baselineGeneration}`,
            });
            break;
        }
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'ProvenanceIncompleteError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.provenanceIncomplete,
        violations,
    };
}

const policyThresholdKeys = new Set([
    'sampling',
    'affinity',
    'startup',
    'provenance',
    'attribution',
    'sessions',
    'thresholds',
    'limits',
    'exit_line',
    'minTimeResolutionMs',
    'executionDominantMaxStartupShare',
    'partiallyResolvableMaxStartupShare',
    'minimumSamples',
]);

/**
 * The validator must read thresholds from the repository, never from the file
 * under test. An artifact may carry a *reference* to the policy it was produced
 * under, but not the policy body.
 */
export function assertNoSelfSuppliedPolicy(artifact, policy) {
    const violations = [];
    const allowed = new Set(policy.artifact.allowedPolicyReferenceKeys);
    const candidates = ['policy', 'contractPolicy', 'measurementPolicy', 'policyRef'];
    for (const key of candidates) {
        const value = artifact?.[key] ?? artifact?.contract?.[key];
        if (value == null) continue;
        if (typeof value !== 'object') {
            violations.push({ rule: 'artifact-policy-payload', detail: `${key} must be an object policy reference` });
            continue;
        }
        for (const field of Object.keys(value)) {
            if (!allowed.has(field)) {
                violations.push({
                    rule: 'artifact-supplied-policy',
                    detail: `artifact ${key}.${field} would override the repository policy; only ${[...allowed].join('/')} may be referenced`,
                });
            }
        }
    }
    for (const key of Object.keys(artifact ?? {})) {
        if (policyThresholdKeys.has(key)) {
            violations.push({
                rule: 'artifact-supplied-policy',
                detail: `artifact top-level key "${key}" carries policy thresholds; the validator reads policy from ${policy.__source?.path}`,
            });
        }
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'ArtifactPolicyOverrideError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.artifactPolicyOverride,
        violations,
    };
}

// ---------------------------------------------------------------------------
// A5: session schema. Session mode is opt-in and never headline eligible.
// ---------------------------------------------------------------------------

export function validateSessionSchema(sessionBlock, policy) {
    const violations = [];
    const rules = policy.sessions;
    if (sessionBlock == null) {
        return { ok: true, errorClass: null, exitCode: CONTRACT_EXIT_CODES.ok, violations };
    }
    if (sessionBlock.schemaVersion !== rules.schemaVersion) {
        violations.push({
            rule: 'session-schema-version',
            detail: `session schemaVersion=${sessionBlock.schemaVersion}, policy requires ${rules.schemaVersion}`,
        });
    }
    if (sessionBlock.enabled && sessionBlock.headlineEligible !== false) {
        violations.push({
            rule: 'session-headline-eligible',
            detail: 'session-mode results may not be headline eligible',
        });
    }
    if (sessionBlock.enabled && !Number.isInteger(sessionBlock.sessions)) {
        violations.push({ rule: 'session-count-invalid', detail: `sessions=${sessionBlock.sessions} must be an integer` });
    }
    if (sessionBlock.enabled && sessionBlock.mixedWithLegacySamples) {
        violations.push({
            rule: 'session-legacy-sample-mixing',
            detail: 'session-mode raw samples were mixed into the legacy one-process-per-case sample pool',
        });
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'SessionSchemaError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.sessionSchema,
        violations,
    };
}

// ---------------------------------------------------------------------------
// A6: P7-42 contracts made automatically checkable.
// ---------------------------------------------------------------------------

const bareFileLine = /^[\w./+-]+\.(?:c|h|zig|cc|cpp|rs|js)?:\d+$/;

export function validateStageAttribution(records, policy) {
    const rules = policy.attribution;
    const allowed = new Set(rules.allowedStageScopes);
    const violations = [];
    for (const record of records ?? []) {
        const label = record.stage ?? record.key ?? '<unnamed>';
        if (!allowed.has(record.scope)) {
            violations.push({
                rule: 'stage-scope-not-allowed',
                detail: `stage ${label} uses scope=${record.scope ?? 'null'}; allowed scopes are ${[...allowed].join('/')}`,
            });
            continue;
        }
        if (rules.forbidBareFileLineScope && typeof record.key === 'string' && bareFileLine.test(record.key)) {
            const qualified =
                (record.scope === 'symbol' && isPresent(record.symbol)) ||
                (record.scope === 'callChain' && isPresent(record.callChain)) ||
                (record.scope === 'addressRange' && isPresent(record.addressRange));
            if (!qualified) {
                violations.push({
                    rule: 'bare-file-line-attribution',
                    detail: `stage ${label} is keyed by the bare file:line "${record.key}" with no symbol/call-chain/address-range qualifier`,
                });
            }
        }
        if (record.scope === 'addressRange' && !isPresent(record.addressRange)) {
            violations.push({ rule: 'address-range-missing', detail: `stage ${label} declares addressRange scope but carries no range` });
        }
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'AttributionScopeError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.attributionScope,
        violations,
    };
}

function gcd(a, b) {
    let x = Math.abs(a);
    let y = Math.abs(b);
    while (y !== 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

export function validatePhaseSampling(input, policy) {
    const rules = policy.attribution;
    const violations = [];
    const argv = input.argv ?? [];
    if (rules.forbidFrequencySamplingForPhaseAttribution) {
        const freqIndex = argv.findIndex((arg) => arg === '-F' || arg === '--freq' || /^-F\d+$/.test(arg));
        if (freqIndex !== -1) {
            violations.push({
                rule: 'frequency-sampling-for-phase-attribution',
                detail: `perf invocation uses ${argv[freqIndex]}; automatic frequency aliases with the inner loop period`,
            });
        }
    }
    if (rules.requireRecordedPeriod) {
        const periodIndex = argv.findIndex((arg) => arg === '-c' || arg === '--count');
        const argvPeriod = periodIndex === -1 ? null : Number(argv[periodIndex + 1]);
        if (!Number.isInteger(argvPeriod) || argvPeriod <= 0) {
            violations.push({ rule: 'phase-period-missing', detail: 'phase attribution requires a fixed perf period (-c N)' });
        } else if (!Number.isInteger(input.recordedPeriod) || input.recordedPeriod !== argvPeriod) {
            violations.push({
                rule: 'phase-period-not-recorded',
                detail: `artifact recordedPeriod=${input.recordedPeriod} does not match the invocation period ${argvPeriod}`,
            });
        } else if (rules.requirePeriodCoprimeWithInnerLoop) {
            if (!Number.isInteger(input.innerLoopPeriod) || input.innerLoopPeriod <= 0) {
                violations.push({
                    rule: 'inner-loop-period-missing',
                    detail: 'the measured inner loop period must be recorded so co-primality can be checked',
                });
            } else if (gcd(argvPeriod, input.innerLoopPeriod) !== 1) {
                violations.push({
                    rule: 'phase-period-not-coprime',
                    detail: `perf period ${argvPeriod} is not co-prime with the inner loop period ${input.innerLoopPeriod}`,
                });
            }
        }
    }
    return {
        ok: violations.length === 0,
        errorClass: violations.length === 0 ? null : 'PhaseSamplingError',
        exitCode: violations.length === 0 ? CONTRACT_EXIT_CODES.ok : CONTRACT_EXIT_CODES.phaseSampling,
        violations,
    };
}

// ---------------------------------------------------------------------------
// Aggregation of the individual checks into one fail-closed verdict.
// ---------------------------------------------------------------------------

export function aggregateVerdict(checks) {
    const failed = checks.filter((check) => check && check.ok === false);
    const violations = failed.flatMap((check) => check.violations.map((v) => ({ ...v, errorClass: check.errorClass })));
    const first = failed[0] ?? null;
    return {
        complete: failed.length === 0,
        errorClass: first?.errorClass ?? null,
        exitCode: first?.exitCode ?? CONTRACT_EXIT_CODES.ok,
        violations,
    };
}
