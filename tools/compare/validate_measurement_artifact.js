#!/usr/bin/env bun

// Standalone validator for whole-process measurement artifacts.
//
// The authoritative policy is read from the repository (tools/compare/
// measurement_policy.json). An artifact that ships its own thresholds is
// rejected outright: the file under test may not move the line it is judged by.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
    CONTRACT_EXIT_CODES,
    aggregateVerdict,
    assertNoSelfSuppliedPolicy,
    loadPolicy,
    policyReference,
    validateAffinityAttestation,
    validateProvenance,
    validateGenerationCoherence,
    validateSampleContract,
    validateWarmupContract,
    validateWorktreeCleanliness,
} from './measurement_contract.js';

function usage() {
    console.log(`Usage: validate_measurement_artifact.js [--formal] [--json] ARTIFACT.json

Validates a run_microbench.js artifact against the repository measurement policy.
Exits non-zero with a contract error class when any rule is violated.

Options:
  --formal   Apply the formal-sampling rules (affinity attestation, provenance,
             clean worktree). Default is structural validation only.
  --json     Emit the machine-readable verdict on stdout.`);
}

const argv = process.argv.slice(2);
let formal = false;
let emitJson = false;
let artifactPath = null;
for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--formal') formal = true;
    else if (arg === '--json') emitJson = true;
    else if (arg === '-h' || arg === '--help') {
        usage();
        process.exit(0);
    } else if (arg.startsWith('-')) {
        console.error(`error: unknown option: ${arg}`);
        process.exit(CONTRACT_EXIT_CODES.usage);
    } else artifactPath = arg;
}
if (!artifactPath) {
    usage();
    process.exit(CONTRACT_EXIT_CODES.usage);
}

const policy = loadPolicy();
const artifact = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), artifactPath), 'utf8'));

export function validateArtifact(subject, options = {}) {
    const isFormal = options.formal ?? false;
    const checks = [];

    const declaredOrders = (subject?.meta?.sampling?.timed?.sampleOrders ?? []).map((order) => order.split('->'));
    const samples = subject?.meta?.sampling?.samples ?? subject?.iters ?? null;
    const okCases = (subject?.cases ?? []).filter((row) => row.status === 'ok');
    for (const row of okCases) {
        const executed = (row.executedOrders ?? []).map((order) =>
            Array.isArray(order) ? order : String(order).split('->'),
        );
        const result = validateSampleContract({ samples, declaredOrders, executedOrders: executed }, policy);
        if (!result.ok) {
            checks.push({ ...result, case: row.name });
            break;
        }
    }
    if (okCases.length === 0) {
        checks.push(
            validateSampleContract({ samples, declaredOrders, executedOrders: [] }, policy),
        );
    } else if (checks.length === 0) {
        checks.push({ ok: true, violations: [], samples, cases: okCases.length });
    }

    if (isFormal) {
        checks.push(validateWarmupContract(subject?.meta?.sampling?.warmup, policy));
        checks.push(
            validateAffinityAttestation(
                {
                    requestedCpu: subject?.meta?.host?.requestedCpu,
                    collectorStart: subject?.meta?.attestation?.collectorStart,
                    collectorEnd: subject?.meta?.attestation?.collectorEnd,
                    children: subject?.meta?.attestation?.children ?? [],
                    pmu: subject?.meta?.host?.pmuIdentity,
                },
                policy,
            ),
        );
        checks.push(validateProvenance(subject, policy));
        checks.push(validateWorktreeCleanliness(subject));
        checks.push(validateGenerationCoherence(subject));
    }
    checks.push(assertNoSelfSuppliedPolicy(subject, policy));

    const verdict = aggregateVerdict(checks);
    return {
        artifact: options.path ?? null,
        policyRef: policyReference(policy),
        formal: isFormal,
        checks,
        ...verdict,
        headline: verdict.complete ? (subject?.summary?.pairedGeomean ?? null) : null,
    };
}

const verdict = validateArtifact(artifact, { formal, path: artifactPath });
if (emitJson) {
    process.stdout.write(`${JSON.stringify(verdict, null, 2)}\n`);
} else {
    console.log(`artifact: ${artifactPath}`);
    console.log(`policy:   ${verdict.policyRef.policy_id} v${verdict.policyRef.policy_version}`);
    console.log(`complete: ${verdict.complete}`);
    console.log(`headline: ${verdict.headline ?? 'null'}`);
    for (const violation of verdict.violations) {
        console.log(`  ${violation.errorClass} ${violation.rule}: ${violation.detail}`);
    }
}
process.exit(verdict.exitCode);
