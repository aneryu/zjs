// Whole-process measurement contract.
//
// Every rule in this module exists because a violation of it already produced a
// wrong answer in this campaign; see reports/perf/qjs-align/measurement-contracts.md
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
