#!/usr/bin/env bun

// Contract tests for the whole-process measurement contract.
//
// Every assertion is specific: exit code, error class, the offending rule id,
// and the message text. "It threw something" is not an accepted outcome.

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import {
    CONTRACT_EXIT_CODES,
    loadPolicy,
    validateSampleContract,
    validateWarmupContract,
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
