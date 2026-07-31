#!/usr/bin/env node

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const process = require('node:process');
const { spawnSync } = require('node:child_process');

const fixedProtocol = Object.freeze({
    iterations: 1,
    warmup: 0,
    teardown_mode: 'normal',
});

const requiredNumericPhases = Object.freeze([
    'runtime_create_ns',
    'context_create_ns',
    'realm_raw_create_ns',
    'realm_bootstrap_ns',
    'realm_ready_ns',
    'compile_ns',
    'parse_ns',
    'compile_frontend_ns',
    'compile_finalize_ns',
    'root_function_publish_ns',
    'first_execute_ns',
    'vm_run_ns',
    'promise_jobs_ns',
    'final_job_drain_ns',
    'engine_cold_to_first_result_ns',
    'eval_total_ns',
    'job_drain_ns',
]);

const requiredNullPhases = Object.freeze([
    'globals_install_ns',
    'context_destroy_ns',
    'runtime_destroy_ns',
]);

const reviewedNumericPhases = new Set(requiredNumericPhases);
const reviewedPhases = new Set([
    ...requiredNumericPhases,
    ...requiredNullPhases,
]);

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'run_zjs_cold_ab.js')} \\
  --baseline PATH --candidate PATH --case NAME --source PATH \\
  --samples EVEN --output PATH [identity options]

Runs one-process-per-sample same-engine cold-phase measurements in repeated
ABBA order. Each harness invocation is fixed to --iterations 1 --warmup 0
--teardown normal.

Required:
  --baseline PATH            Baseline zjs-same-runtime harness
  --candidate PATH           Candidate zjs-same-runtime harness
  --case NAME                Case name passed to both harnesses
  --source PATH              Exact source passed to both harnesses
  --samples EVEN             Positive even number of matched A/B pairs
  --output PATH              Summary JSON output

Optional identity metadata:
  --baseline-identity PATH   Precomputed symbol identity JSON for baseline
  --candidate-identity PATH  Precomputed symbol identity JSON for candidate
  -h, --help                 Show this help

This collector does not infer build-state equivalence. macOS CPU-affinity
verification is unavailable and is recorded as such; output remains useful for
same-machine diagnostics.`);
}

function fail(message) {
    console.error(`error: ${message}`);
    process.exit(2);
}

function optionValue(args, index, option) {
    const value = args[index + 1];
    if (value == null) fail(`${option} requires a value`);
    return value;
}

function parseArgs() {
    const config = {
        baseline: null,
        candidate: null,
        caseName: null,
        source: null,
        samples: null,
        output: null,
        baselineIdentity: null,
        candidateIdentity: null,
    };
    const seen = new Set();
    const args = process.argv.slice(2);
    for (let index = 0; index < args.length; index += 1) {
        const option = args[index];
        if (option === '-h' || option === '--help') {
            usage();
            process.exit(0);
        }
        const fields = {
            '--baseline': 'baseline',
            '--candidate': 'candidate',
            '--case': 'caseName',
            '--source': 'source',
            '--samples': 'samples',
            '--output': 'output',
            '--baseline-identity': 'baselineIdentity',
            '--candidate-identity': 'candidateIdentity',
        };
        const field = fields[option];
        if (field == null) fail(`unknown option: ${option}`);
        if (seen.has(option)) fail(`${option} may be specified only once`);
        seen.add(option);
        const value = optionValue(args, index, option);
        index += 1;
        config[field] = value;
    }

    for (const [option, field] of [
        ['--baseline', 'baseline'],
        ['--candidate', 'candidate'],
        ['--case', 'caseName'],
        ['--source', 'source'],
        ['--samples', 'samples'],
        ['--output', 'output'],
    ]) {
        if (config[field] == null) fail(`${option} is required`);
    }
    if (!/^[A-Za-z0-9_.-]+$/.test(config.caseName)) {
        fail('--case must contain only letters, digits, dot, underscore, or dash');
    }
    const samples = Number(config.samples);
    if (
        !Number.isSafeInteger(samples) ||
        samples <= 0 ||
        samples > 10000 ||
        samples % 2 !== 0
    ) {
        fail('--samples must be a positive even integer at most 10000');
    }
    config.samples = samples;
    return config;
}

function realFile(value, label, executable = false) {
    const requested = path.resolve(process.cwd(), value);
    let resolved;
    try {
        resolved = fs.realpathSync(requested);
        const stat = fs.statSync(resolved);
        if (!stat.isFile()) throw new Error('not a regular file');
        if (executable) fs.accessSync(resolved, fs.constants.X_OK);
    } catch (error) {
        fail(`${label} is not an accessible${executable ? ' executable' : ''} file: ${requested}: ${error.message}`);
    }
    return resolved;
}

function sha256File(filePath) {
    const digest = crypto.createHash('sha256');
    digest.update(fs.readFileSync(filePath));
    return digest.digest('hex');
}

function parseIdentity(identityPath, harnessSha256, label) {
    if (identityPath == null) return null;
    const resolved = realFile(identityPath, `${label} identity`);
    let identity;
    try {
        identity = JSON.parse(fs.readFileSync(resolved, 'utf8'));
    } catch (error) {
        fail(`${label} identity is not valid JSON: ${error.message}`);
    }
    if (
        identity == null ||
        typeof identity !== 'object' ||
        Array.isArray(identity)
    ) {
        fail(`${label} identity must be a JSON object`);
    }
    const signature = identity.global_normalized_signature;
    if (typeof signature !== 'string' || !/^[0-9a-f]{64}$/.test(signature)) {
        fail(`${label} identity has no valid global_normalized_signature`);
    }
    const declaredBinarySha = identity.binary_sha256 ?? null;
    if (
        declaredBinarySha !== null &&
        (typeof declaredBinarySha !== 'string' ||
            !/^[0-9a-f]{64}$/.test(declaredBinarySha))
    ) {
        fail(`${label} identity binary_sha256 must be null or lowercase SHA-256`);
    }
    if (
        declaredBinarySha !== null &&
        declaredBinarySha !== harnessSha256
    ) {
        fail(`${label} identity binary_sha256 does not match the harness binary`);
    }
    return {
        path: resolved,
        global_normalized_signature: signature,
        binary_sha256: declaredBinarySha,
        binary_sha256_matches_harness:
            declaredBinarySha === null ? null : true,
        interpretation:
            'Metadata only; this runner makes no build-state equivalence conclusion.',
    };
}

function isNonNegativeSafeInteger(value) {
    return Number.isSafeInteger(value) && value >= 0;
}

function hasOwn(object, name) {
    return Object.prototype.hasOwnProperty.call(object, name);
}

function validateHarnessRecord(record, expected) {
    const errors = [];
    if (
        record == null ||
        typeof record !== 'object' ||
        Array.isArray(record)
    ) {
        return ['stdout JSON must be an object'];
    }
    for (const [field, value] of [
        ['engine', 'zjs'],
        ['layer', 'same-runtime'],
        ['case', expected.caseName],
        ['source_sha256', expected.sourceSha256],
        ['teardown_mode', fixedProtocol.teardown_mode],
    ]) {
        if (record[field] !== value) {
            errors.push(`${field} must be ${JSON.stringify(value)}`);
        }
    }
    for (const [field, value] of [
        ['compiles', 1],
        ['top_level_executions', 1],
        ['iterations', fixedProtocol.iterations],
        ['warmup', fixedProtocol.warmup],
    ]) {
        if (record[field] !== value) {
            errors.push(`${field} must be the measured integer ${value}`);
        }
    }
    if (
        typeof record.result_checksum !== 'string' ||
        record.result_checksum.length === 0
    ) {
        errors.push('result_checksum must be a non-empty string');
    }
    if (
        record.build == null ||
        typeof record.build !== 'object' ||
        Array.isArray(record.build) ||
        typeof record.build.mode !== 'string' ||
        record.build.mode.length === 0
    ) {
        errors.push('build.mode must be a non-empty string');
    }
    if (
        record.jsvalue_representation == null ||
        typeof record.jsvalue_representation !== 'object' ||
        Array.isArray(record.jsvalue_representation) ||
        !Number.isSafeInteger(record.jsvalue_representation.size_bytes) ||
        record.jsvalue_representation.size_bytes <= 0 ||
        typeof record.jsvalue_representation.nan_boxing !== 'boolean'
    ) {
        errors.push(
            'jsvalue_representation must declare positive size_bytes and boolean nan_boxing',
        );
    }
    if (
        record.phases == null ||
        typeof record.phases !== 'object' ||
        Array.isArray(record.phases)
    ) {
        errors.push('phases must be an object');
        return errors;
    }
    for (const name of requiredNumericPhases) {
        if (!hasOwn(record.phases, name)) {
            errors.push(`phases.${name} is required`);
        } else if (!isNonNegativeSafeInteger(record.phases[name])) {
            errors.push(`phases.${name} must be a non-negative safe integer`);
        }
    }
    for (const name of requiredNullPhases) {
        if (!hasOwn(record.phases, name)) {
            errors.push(`phases.${name} is required`);
        } else if (record.phases[name] !== null) {
            errors.push(`phases.${name} must be null under teardown normal`);
        }
    }
    for (const [name, value] of Object.entries(record.phases)) {
        if (value !== null && !isNonNegativeSafeInteger(value)) {
            errors.push(
                `phases.${name} must be null or a non-negative safe integer`,
            );
        }
    }
    const promiseJobs = record.phases.promise_jobs_ns;
    const finalJobs = record.phases.final_job_drain_ns;
    const allJobs = record.phases.job_drain_ns;
    if (
        isNonNegativeSafeInteger(promiseJobs) &&
        isNonNegativeSafeInteger(finalJobs) &&
        isNonNegativeSafeInteger(allJobs) &&
        allJobs !== promiseJobs + finalJobs
    ) {
        errors.push(
            'phases.job_drain_ns must equal promise_jobs_ns + final_job_drain_ns',
        );
    }
    if (
        record.steady_execute == null ||
        !Array.isArray(record.steady_execute.samples_ns) ||
        record.steady_execute.samples_ns.length !== 1 ||
        !record.steady_execute.samples_ns.every(isNonNegativeSafeInteger)
    ) {
        errors.push('steady_execute.samples_ns must contain one non-negative integer');
    } else if (
        !isNonNegativeSafeInteger(record.steady_execute.median_ns) ||
        record.steady_execute.median_ns !==
            record.steady_execute.samples_ns[0]
    ) {
        errors.push(
            'steady_execute.median_ns must equal the sole measured sample',
        );
    }
    return errors;
}

function assertFileSha256(filePath, expectedSha256, label) {
    const observed = sha256File(filePath);
    if (observed !== expectedSha256) {
        throw new Error(
            `${label} changed during collection: expected ${expectedSha256}, got ${observed}`,
        );
    }
    return observed;
}

function runHarness(
    role,
    harnessPath,
    harnessSha256,
    expected,
    pairIndex,
    orderIndex,
) {
    const binarySha256Before = assertFileSha256(
        harnessPath,
        harnessSha256,
        `pair ${pairIndex} ${role} harness`,
    );
    const sourceSha256Before = assertFileSha256(
        expected.sourcePath,
        expected.sourceSha256,
        `pair ${pairIndex} source`,
    );
    const args = [
        '--case',
        expected.caseName,
        '--source',
        expected.sourcePath,
        '--iterations',
        String(fixedProtocol.iterations),
        '--warmup',
        String(fixedProtocol.warmup),
        '--teardown',
        fixedProtocol.teardown_mode,
    ];
    const result = spawnSync(harnessPath, args, {
        cwd: process.cwd(),
        encoding: 'utf8',
        maxBuffer: 128 * 1024 * 1024,
    });
    const prefix = `pair ${pairIndex} ${role} invocation ${orderIndex}`;
    const binarySha256After = assertFileSha256(
        harnessPath,
        harnessSha256,
        `${prefix} harness`,
    );
    const sourceSha256After = assertFileSha256(
        expected.sourcePath,
        expected.sourceSha256,
        `${prefix} source`,
    );
    if (result.error) {
        throw new Error(`${prefix} spawn failed: ${result.error.message}`);
    }
    if (result.status !== 0) {
        if (result.status == null) {
            throw new Error(
                `${prefix} terminated by signal ${result.signal || 'unknown'}`,
            );
        }
        throw new Error(`${prefix} exited with status ${result.status}`);
    }
    if (result.stderr !== '') {
        throw new Error(`${prefix} wrote non-empty stderr`);
    }
    let record;
    try {
        record = JSON.parse(result.stdout);
    } catch (error) {
        throw new Error(`${prefix} stdout was not one valid JSON document: ${error.message}`);
    }
    const errors = validateHarnessRecord(record, expected);
    if (errors.length > 0) {
        throw new Error(`${prefix} record invalid: ${errors.join('; ')}`);
    }
    return {
        role,
        process: {
            binary_path: harnessPath,
            binary_sha256_before: binarySha256Before,
            binary_sha256_after: binarySha256After,
            source_sha256_before: sourceSha256Before,
            source_sha256_after: sourceSha256After,
            exit_code: result.status,
            signal: result.signal || null,
            stderr_empty: true,
        },
        record,
    };
}

function quantile(sorted, fraction) {
    if (sorted.length === 1) return sorted[0];
    const position = (sorted.length - 1) * fraction;
    const lower = Math.floor(position);
    const upper = Math.ceil(position);
    if (lower === upper) return sorted[lower];
    const weight = position - lower;
    return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

function numericStats(values) {
    if (values.length === 0) return null;
    const sorted = [...values].sort((left, right) => left - right);
    return {
        sample_count: values.length,
        p25: quantile(sorted, 0.25),
        median: quantile(sorted, 0.5),
        p75: quantile(sorted, 0.75),
    };
}

function summarizePhases(pairs) {
    const phaseNames = new Set();
    for (const pair of pairs) {
        for (const role of ['baseline', 'candidate']) {
            for (const name of Object.keys(pair[role].record.phases)) {
                phaseNames.add(name);
            }
        }
    }

    const endpoints = { baseline: {}, candidate: {} };
    const paired = {};
    for (const name of [...phaseNames].sort()) {
        const baselineValues = [];
        const candidateValues = [];
        for (const pair of pairs) {
            const baseline = pair.baseline.record.phases[name];
            const candidate = pair.candidate.record.phases[name];
            if (isNonNegativeSafeInteger(baseline)) {
                baselineValues.push(baseline);
            }
            if (isNonNegativeSafeInteger(candidate)) {
                candidateValues.push(candidate);
            }
        }
        endpoints.baseline[name] = numericStats(baselineValues);
        endpoints.candidate[name] = numericStats(candidateValues);

        if (!reviewedPhases.has(name)) {
            paired[name] = {
                status: 'raw-only',
                reason:
                    'Unknown phase is retained but no candidate/baseline ratio is published without an explicit runner contract.',
                stats: null,
            };
            continue;
        }
        if (!reviewedNumericPhases.has(name)) {
            paired[name] = {
                status: 'raw-only',
                reason: 'This phase is null by the fixed normal-teardown contract.',
                stats: null,
            };
            continue;
        }
        if (
            baselineValues.length !== pairs.length ||
            candidateValues.length !== pairs.length
        ) {
            paired[name] = {
                status: 'raw-only',
                reason: 'A reviewed numeric phase was unavailable in at least one pair.',
                stats: null,
            };
            continue;
        }
        const ratios = [];
        let zeroBaseline = false;
        for (const pair of pairs) {
            const baseline = pair.baseline.record.phases[name];
            const candidate = pair.candidate.record.phases[name];
            if (baseline === 0) {
                zeroBaseline = true;
            } else {
                ratios.push(candidate / baseline);
            }
        }
        paired[name] = zeroBaseline
            ? {
                status: 'raw-only',
                reason:
                    'At least one baseline value was zero; division is suppressed instead of dropping that pair.',
                stats: null,
            }
            : {
                status: 'paired',
                reason: null,
                stats: numericStats(ratios),
            };
    }
    return { endpoints, paired };
}

function affinityMetadata() {
    if (process.platform === 'darwin') {
        return {
            platform: process.platform,
            status: 'unavailable',
            query_supported: false,
            pinned: false,
            reason:
                'This runner has no supported macOS CPU-affinity query or pinning mechanism.',
        };
    }
    if (process.platform === 'linux') {
        let allowed = null;
        try {
            const status = fs.readFileSync('/proc/self/status', 'utf8');
            allowed = status.match(/^Cpus_allowed_list:\s*(.+)$/m)?.[1]?.trim() ?? null;
        } catch {
            allowed = null;
        }
        return {
            platform: process.platform,
            status: 'observed-parent-only',
            query_supported: allowed !== null,
            pinned: false,
            allowed_cpus: allowed,
            reason:
                'No child-affinity verification is performed; this artifact remains diagnostic-only.',
        };
    }
    return {
        platform: process.platform,
        status: 'unavailable',
        query_supported: false,
        pinned: false,
        reason: `CPU-affinity verification is unsupported on ${process.platform}.`,
    };
}

function main() {
    const config = parseArgs();
    const baselinePath = realFile(config.baseline, '--baseline', true);
    const candidatePath = realFile(config.candidate, '--candidate', true);
    const sourcePath = realFile(config.source, '--source');
    const outputPath = path.resolve(process.cwd(), config.output);
    const sourceSha256 = sha256File(sourcePath);
    const baselineSha256 = sha256File(baselinePath);
    const candidateSha256 = sha256File(candidatePath);
    const expected = {
        caseName: config.caseName,
        sourcePath,
        sourceSha256,
    };

    const artifacts = {
        baseline: {
            path: baselinePath,
            sha256: baselineSha256,
            identity: parseIdentity(
                config.baselineIdentity,
                baselineSha256,
                'baseline',
            ),
        },
        candidate: {
            path: candidatePath,
            sha256: candidateSha256,
            identity: parseIdentity(
                config.candidateIdentity,
                candidateSha256,
                'candidate',
            ),
        },
    };

    const pairs = [];
    let expectedChecksum = null;
    let expectedBuild = null;
    let expectedRepresentation = null;
    for (let pairIndex = 0; pairIndex < config.samples; pairIndex += 1) {
        const order =
            pairIndex % 2 === 0
                ? ['baseline', 'candidate']
                : ['candidate', 'baseline'];
        const invocations = order.map((role, orderIndex) =>
            runHarness(
                role,
                artifacts[role].path,
                artifacts[role].sha256,
                expected,
                pairIndex,
                orderIndex,
            ),
        );
        for (const invocation of invocations) {
            const checksum = invocation.record.result_checksum;
            if (expectedChecksum === null) {
                expectedChecksum = checksum;
            } else if (checksum !== expectedChecksum) {
                throw new Error(
                    `pair ${pairIndex} ${invocation.role} result_checksum mismatch: ` +
                    `${JSON.stringify(checksum)} != ${JSON.stringify(expectedChecksum)}`,
                );
            }
            const build = JSON.stringify(invocation.record.build);
            const representation = JSON.stringify(
                invocation.record.jsvalue_representation,
            );
            if (expectedBuild === null) {
                expectedBuild = build;
                expectedRepresentation = representation;
            } else {
                if (build !== expectedBuild) {
                    throw new Error(
                        `pair ${pairIndex} ${invocation.role} build metadata does not match the first invocation`,
                    );
                }
                if (representation !== expectedRepresentation) {
                    throw new Error(
                        `pair ${pairIndex} ${invocation.role} JSValue representation does not match the first invocation`,
                    );
                }
            }
        }
        pairs.push({
            pair_index: pairIndex,
            order,
            invocations,
            baseline: invocations.find(
                (invocation) => invocation.role === 'baseline',
            ),
            candidate: invocations.find(
                (invocation) => invocation.role === 'candidate',
            ),
        });
    }

    for (const role of ['baseline', 'candidate']) {
        artifacts[role].post_run_sha256 = assertFileSha256(
            artifacts[role].path,
            artifacts[role].sha256,
            `${role} harness`,
        );
        artifacts[role].unchanged_during_collection = true;
    }
    const postRunSourceSha256 = assertFileSha256(
        sourcePath,
        sourceSha256,
        'source',
    );
    const phaseSummary = summarizePhases(pairs);
    const affinity = affinityMetadata();
    const output = {
        tool: 'zjs-cold-ab',
        layer: 'same-runtime',
        generated_at: new Date().toISOString(),
        case: config.caseName,
        source: {
            path: sourcePath,
            sha256: sourceSha256,
            post_run_sha256: postRunSourceSha256,
            unchanged_during_collection: true,
        },
        protocol: {
            ...fixedProtocol,
            pair_count: config.samples,
            process_invocations: config.samples * 2,
            sampling_order: 'ABBA',
            abba_blocks: config.samples / 2,
            ratio_definition:
                'candidate/baseline within each matched pair',
        },
        affinity,
        diagnostic_scope: {
            same_engine: true,
            formal_comparison: false,
            build_state_equivalence_conclusion: null,
            reason:
                'Same-machine cold-phase diagnostic only; affinity and build-state equivalence are not established by this runner.',
        },
        phase_schema: {
            required_numeric: requiredNumericPhases,
            required_null: requiredNullPhases,
            unknown_phase_policy:
                'retain raw records and endpoint statistics; suppress ratio as raw-only',
            missing_required_phase_policy: 'fail closed',
        },
        artifacts,
        result_checksum: expectedChecksum,
        raw_pairs: pairs.map((pair) => ({
            pair_index: pair.pair_index,
            order: pair.order,
            invocations: pair.invocations,
        })),
        endpoint_phase_statistics_ns: phaseSummary.endpoints,
        paired_candidate_over_baseline: phaseSummary.paired,
    };

    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, `${JSON.stringify(output, null, 2)}\n`);
    console.log(
        `${config.caseName}: ${config.samples} ABBA pairs -> ${outputPath}`,
    );
}

try {
    main();
} catch (error) {
    fail(error instanceof Error ? error.message : String(error));
}
