#!/usr/bin/env node

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const process = require('node:process');
const { spawnSync } = require('node:child_process');

const expectedQjsHead = '04be246001599f5995fa2f2d8c91a0f198d3f34c';
const expectedQjsVersion = '2026-06-04';
const scriptDir = __dirname;
const policyPath = path.join(scriptDir, 'policy.json');

function exactObjectKeys(value, expectedKeys, label) {
    if (value == null || typeof value !== 'object' || Array.isArray(value)) {
        throw new Error(`${label} must be an object`);
    }
    const expected = new Set(expectedKeys);
    const missing = expectedKeys.filter(
        (key) => !Object.prototype.hasOwnProperty.call(value, key),
    );
    const unexpected = Object.keys(value).filter((key) => !expected.has(key));
    if (missing.length > 0) {
        throw new Error(`${label} is missing field(s): ${missing.join(', ')}`);
    }
    if (unexpected.length > 0) {
        throw new Error(
            `${label} has unexpected field(s): ${unexpected.join(', ')}`,
        );
    }
}

function loadSameRuntimePolicy(filePath) {
    let contents;
    try {
        contents = fs.readFileSync(filePath, 'utf8');
    } catch (error) {
        throw new Error(`cannot read ${filePath}: ${error.message}`);
    }

    let parsed;
    try {
        parsed = JSON.parse(contents);
    } catch (error) {
        throw new Error(`invalid JSON in ${filePath}: ${error.message}`);
    }

    exactObjectKeys(
        parsed,
        ['policy_id', 'policy_version', 'sentinels', 'exit_line'],
        'policy',
    );
    if (
        typeof parsed.policy_id !== 'string' ||
        parsed.policy_id.trim().length === 0
    ) {
        throw new Error('policy.policy_id must be a non-empty string');
    }
    if (
        !Number.isSafeInteger(parsed.policy_version) ||
        parsed.policy_version < 1
    ) {
        throw new Error('policy.policy_version must be a positive integer');
    }
    if (!Array.isArray(parsed.sentinels) || parsed.sentinels.length === 0) {
        throw new Error('policy.sentinels must be a non-empty array');
    }

    const seenNames = new Set();
    const sentinels = parsed.sentinels.map((entry, index) => {
        const label = `policy.sentinels[${index}]`;
        exactObjectKeys(
            entry,
            ['name', 'checksum_required', 'case_shape', 'provenance'],
            label,
        );
        if (
            typeof entry.name !== 'string' ||
            !/^[A-Za-z0-9_.-]+$/.test(entry.name)
        ) {
            throw new Error(`${label}.name must be a valid case name`);
        }
        if (seenNames.has(entry.name)) {
            throw new Error(`duplicate sentinel name: ${entry.name}`);
        }
        seenNames.add(entry.name);
        if (typeof entry.checksum_required !== 'boolean') {
            throw new Error(`${label}.checksum_required must be a boolean`);
        }
        for (const field of ['case_shape', 'provenance']) {
            if (
                typeof entry[field] !== 'string' ||
                entry[field].trim().length === 0
            ) {
                throw new Error(`${label}.${field} must be a non-empty string`);
            }
        }
        return Object.freeze({ ...entry });
    });

    exactObjectKeys(
        parsed.exit_line,
        ['geomean_limit', 'per_case_limit'],
        'policy.exit_line',
    );
    for (const field of ['geomean_limit', 'per_case_limit']) {
        const value = parsed.exit_line[field];
        if (!Number.isFinite(value) || value <= 0) {
            throw new Error(
                `policy.exit_line.${field} must be a positive finite number`,
            );
        }
    }

    return Object.freeze({
        policy_id: parsed.policy_id,
        policy_version: parsed.policy_version,
        sentinels: Object.freeze(sentinels),
        exit_line: Object.freeze({ ...parsed.exit_line }),
    });
}

let sameRuntimePolicy;
try {
    sameRuntimePolicy = loadSameRuntimePolicy(policyPath);
} catch (error) {
    fail(`cannot load checked-in same-runtime policy: ${error.message}`);
}
const p0SentinelNames = sameRuntimePolicy.sentinels.map(
    (sentinel) => sentinel.name,
);
const caseMetadata = Object.fromEntries(
    sameRuntimePolicy.sentinels.map(({ name, ...metadata }) => [
        name,
        Object.freeze(metadata),
    ]),
);
const repoRoot = process.env.ZJS_REPO_ROOT
    ? path.resolve(process.env.ZJS_REPO_ROOT)
    : path.resolve(scriptDir, '../../..');
const phaseRatioFloorNs = 1000;
const pmuEvents = [
    'instructions',
    'cycles',
    'branches',
    'branch-misses',
];

const config = {
    cases: [...p0SentinelNames],
    caseSources: new Map(),
    iterations: 200,
    warmup: 20,
    samples: 5,
    teardown: 'normal',
    cpu: 19,
    output: path.join(
        repoRoot,
        '.zig-cache/perf/qjs-align/same-runtime/summary.json',
    ),
    zjsHarness: path.join(repoRoot, 'zig-out/bin/zjs-same-runtime'),
    qjsHarness: path.join(
        repoRoot,
        '.zig-cache/perf/qjs-align/same-runtime/qjs-same-runtime',
    ),
    zig: process.env.ZIG || 'zig',
    pmu: true,
    selectedPmu: null,
};

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'run_same_runtime.js')} [options]

Runs paired zjs/QuickJS compile-once, execute-many samples pinned to one CPU.

Options:
  --cases a,b,c          Cases to run (default: all policy sentinels)
  --case-source NAME=PATH
                         Override/add a case source; use --cases NAME to select a custom name
  --iterations N         Timed run() calls per harness invocation (default: 200)
  --warmup N             Untimed run() calls per invocation (default: 20)
  --samples K            Paired harness invocations per case (default: 5)
  --teardown MODE        normal or leak-check (default: normal)
  --cpu N                CPU passed to taskset -c (default: 19)
  --output PATH          Summary JSON path (default: .zig-cache/perf/qjs-align/same-runtime/summary.json)
  --zjs-harness PATH     zjs harness path (default: zig-out/bin/zjs-same-runtime)
  --qjs-harness PATH     qjs harness path (default: .zig-cache/perf/qjs-align/same-runtime/qjs-same-runtime)
  --zig PATH             Zig executable used for environment metadata
  --no-pmu               Skip the separate perf-stat invocations
  -h, --help             Show this help`);
}

function fail(message, code = 2) {
    console.error(`error: ${message}`);
    process.exit(code);
}

function optionValue(args, index, label) {
    const value = args[index + 1];
    if (value == null) fail(`${label} requires a value`);
    return value;
}

function parseInteger(text, label, allowZero = false) {
    const value = Number(text);
    if (
        !Number.isSafeInteger(value) ||
        value < (allowZero ? 0 : 1) ||
        value > 1_000_000
    ) {
        fail(
            `${label} must be a ${allowZero ? 'non-negative' : 'positive'} integer at most 1000000`,
        );
    }
    return value;
}

function absoluteFromCwd(value) {
    return path.resolve(process.cwd(), value);
}

function parseArgs() {
    const args = process.argv.slice(2);
    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        switch (arg) {
            case '--cases': {
                const requested = optionValue(args, i, '--cases')
                    .split(',')
                    .filter((name) => name.length > 0);
                i += 1;
                if (requested.length === 0) fail('--cases must not be empty');
                config.cases = [...new Set(requested)];
                break;
            }
            case '--case-source': {
                const mapping = optionValue(args, i, '--case-source');
                i += 1;
                const separator = mapping.indexOf('=');
                if (separator <= 0 || separator === mapping.length - 1) {
                    fail('--case-source must use NAME=PATH');
                }
                const name = mapping.slice(0, separator);
                if (!/^[A-Za-z0-9_.-]+$/.test(name)) {
                    fail(`invalid --case-source name: ${name}`);
                }
                config.caseSources.set(
                    name,
                    absoluteFromCwd(mapping.slice(separator + 1)),
                );
                break;
            }
            case '--iterations':
                config.iterations = parseInteger(
                    optionValue(args, i, '--iterations'),
                    '--iterations',
                );
                i += 1;
                break;
            case '--warmup':
                config.warmup = parseInteger(
                    optionValue(args, i, '--warmup'),
                    '--warmup',
                    true,
                );
                i += 1;
                break;
            case '--samples':
                config.samples = parseInteger(
                    optionValue(args, i, '--samples'),
                    '--samples',
                );
                i += 1;
                break;
            case '--teardown':
                config.teardown = optionValue(args, i, '--teardown');
                i += 1;
                if (!['normal', 'leak-check'].includes(config.teardown)) {
                    fail('--teardown must be normal or leak-check');
                }
                break;
            case '--cpu':
                config.cpu = parseInteger(
                    optionValue(args, i, '--cpu'),
                    '--cpu',
                    true,
                );
                i += 1;
                break;
            case '--output':
                config.output = absoluteFromCwd(optionValue(args, i, '--output'));
                i += 1;
                break;
            case '--zjs-harness':
                config.zjsHarness = absoluteFromCwd(
                    optionValue(args, i, '--zjs-harness'),
                );
                i += 1;
                break;
            case '--qjs-harness':
                config.qjsHarness = absoluteFromCwd(
                    optionValue(args, i, '--qjs-harness'),
                );
                i += 1;
                break;
            case '--zig':
                config.zig = optionValue(args, i, '--zig');
                i += 1;
                break;
            case '--no-pmu':
                config.pmu = false;
                break;
            case '-h':
            case '--help':
                usage();
                process.exit(0);
                break;
            default:
                fail(`unknown option: ${arg}`);
        }
    }
    for (const name of config.cases) {
        const sourcePath = caseSourcePath(name);
        if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isFile()) {
            fail(
                `case ${name} has no source file; expected ${sourcePath} or pass --case-source ${name}=PATH`,
            );
        }
    }
}

function runCommand(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: options.cwd || repoRoot,
        encoding: 'utf8',
        maxBuffer: 128 * 1024 * 1024,
    });
    if (result.error) {
        fail(`failed to run ${command}: ${result.error.message}`, 1);
    }
    if (result.status !== 0) {
        if (result.stdout) process.stderr.write(result.stdout);
        if (result.stderr) process.stderr.write(result.stderr);
        fail(
            `${command} ${args.join(' ')} exited with status ${result.status}`,
            result.status || 1,
        );
    }
    return result.stdout.trim();
}

function commandFirstLine(command, args, options = {}) {
    return runCommand(command, args, options).split(/\r?\n/, 1)[0];
}

function captureCommand(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: options.cwd || repoRoot,
        encoding: 'utf8',
        maxBuffer: 128 * 1024 * 1024,
    });
    return {
        command: [command, ...args],
        exit_code: result.status,
        signal: result.signal || null,
        stdout: result.stdout || '',
        stderr: result.stderr || '',
        spawn_error: result.error ? result.error.message : null,
    };
}

function sha256File(filePath) {
    return crypto
        .createHash('sha256')
        .update(fs.readFileSync(filePath))
        .digest('hex');
}

function parseCpuSet(text) {
    const cpus = new Set();
    for (const rawPart of text.trim().split(',')) {
        const part = rawPart.trim();
        if (part.length === 0) continue;
        if (part.includes('-')) {
            const [lowerText, upperText] = part.split('-', 2);
            const lower = Number(lowerText);
            const upper = Number(upperText);
            if (
                !Number.isSafeInteger(lower) ||
                !Number.isSafeInteger(upper) ||
                lower > upper
            ) {
                throw new Error(`invalid CPU range ${part}`);
            }
            for (let cpu = lower; cpu <= upper; cpu += 1) cpus.add(cpu);
        } else {
            const cpu = Number(part);
            if (!Number.isSafeInteger(cpu)) {
                throw new Error(`invalid CPU id ${part}`);
            }
            cpus.add(cpu);
        }
    }
    return [...cpus].sort((left, right) => left - right);
}

function discoverPmuForCpu(cpu) {
    const devicesRoot = '/sys/bus/event_source/devices';
    let names = [];
    try {
        names = fs
            .readdirSync(devicesRoot)
            .filter((name) => name.startsWith('armv8_pmuv3_'))
            .sort();
    } catch (error) {
        return {
            passed: false,
            cpu,
            name: null,
            candidates: [],
            reason: `could not enumerate ${devicesRoot}: ${error.message}`,
        };
    }
    const candidates = names.map((name) => {
        const cpusPath = path.join(devicesRoot, name, 'cpus');
        try {
            return {
                name,
                cpus: parseCpuSet(fs.readFileSync(cpusPath, 'utf8')),
                reason: null,
            };
        } catch (error) {
            return {
                name,
                cpus: null,
                reason: `could not read ${cpusPath}: ${error.message}`,
            };
        }
    });
    const matches = candidates.filter(
        (candidate) =>
            Array.isArray(candidate.cpus) && candidate.cpus.includes(cpu),
    );
    return {
        passed: matches.length === 1,
        cpu,
        name: matches.length === 1 ? matches[0].name : null,
        candidates,
        reason:
            matches.length === 1
                ? null
                : `CPU ${cpu} maps to ${matches.length} armv8 PMU devices; exactly one is required`,
    };
}

function probeTasksetAffinity(cpu) {
    const probe = [
        "const fs = require('node:fs');",
        "const text = fs.readFileSync('/proc/self/status', 'utf8');",
        "const match = text.match(/^Cpus_allowed_list:\\s*(.+)$/m);",
        "if (!match) process.exit(3);",
        'console.log(JSON.stringify(match[1].trim()));',
    ].join('');
    const result = spawnSync(
        'taskset',
        ['-c', String(cpu), process.execPath, '-e', probe],
        {
            cwd: repoRoot,
            encoding: 'utf8',
            maxBuffer: 1024 * 1024,
        },
    );
    let observedText = null;
    let observedCpus = null;
    let parseError = null;
    try {
        observedText = JSON.parse((result.stdout || '').trim());
        observedCpus = parseCpuSet(observedText);
    } catch (error) {
        parseError = error.message;
    }
    const passed =
        !result.error &&
        result.status === 0 &&
        (!result.stderr || result.stderr.length === 0) &&
        observedCpus?.length === 1 &&
        observedCpus[0] === cpu;
    const reasons = [];
    if (result.error) reasons.push(`spawn failed: ${result.error.message}`);
    if (result.status !== 0) reasons.push(`taskset probe exited ${result.status}`);
    if (result.stderr) reasons.push('taskset probe stderr was non-empty');
    if (observedCpus?.length !== 1 || observedCpus?.[0] !== cpu) {
        reasons.push(
            `observed affinity was ${JSON.stringify(observedCpus)}, expected [${cpu}]`,
        );
    }
    if (parseError) reasons.push(`affinity output parse failed: ${parseError}`);
    return {
        passed,
        requested_cpu: cpu,
        observed_affinity_text: observedText,
        observed_cpus: observedCpus,
        exit_code: result.status,
        stderr: result.stderr || '',
        reason: passed ? null : reasons.join('; '),
    };
}

function caseSourcePath(caseName) {
    const override = config.caseSources.get(caseName);
    if (override) return override;
    return path.join(scriptDir, 'cases', `${caseName}.js`);
}

function checksumRequirementForCase(caseName) {
    const metadata = caseMetadata[caseName];
    const declared =
        metadata != null && typeof metadata.checksum_required === 'boolean';
    return {
        required: declared ? metadata.checksum_required : true,
        declared,
    };
}

function validateHarnessRecord(record, engine, caseName, iterations, warmup) {
    const errors = [];
    if (!record || typeof record !== 'object') {
        return [`${engine} returned a non-object JSON value for ${caseName}`];
    }
    if (record.engine !== engine) errors.push(`engine must be ${engine}`);
    if (record.layer !== 'same-runtime') errors.push('layer must be same-runtime');
    if (record.case !== caseName) errors.push(`case must be ${caseName}`);
    if (record.compiles !== 1) {
        errors.push(`compiles must be the measured integer 1, got ${record.compiles}`);
    }
    if (record.top_level_executions !== 1) {
        errors.push(
            `top_level_executions must be the measured integer 1, got ${record.top_level_executions}`,
        );
    }
    if (record.teardown_mode !== config.teardown) {
        errors.push(`teardown_mode must be ${config.teardown}`);
    }
    if (record.iterations !== iterations) {
        errors.push(`iterations must be ${iterations}`);
    }
    if (record.warmup !== warmup) errors.push(`warmup must be ${warmup}`);
    if (
        typeof record.source_sha256 !== 'string' ||
        !/^[0-9a-f]{64}$/.test(record.source_sha256)
    ) {
        errors.push('source_sha256 must be a non-empty lowercase SHA-256');
    }
    const checksumRequirement = checksumRequirementForCase(caseName);
    if (checksumRequirement.required) {
        if (
            typeof record.result_checksum !== 'string' ||
            record.result_checksum.trim().length === 0
        ) {
            errors.push(
                'result_checksum is required and must be a non-empty string',
            );
        }
    } else if (
        record.result_checksum != null &&
        typeof record.result_checksum !== 'string'
    ) {
        errors.push(
            'result_checksum must be a string when an optional checksum is reported',
        );
    }
    if (!record.build || typeof record.build !== 'object') {
        errors.push('build metadata is missing');
    }
    if (
        !record.jsvalue_representation ||
        !Number.isSafeInteger(record.jsvalue_representation.size_bytes) ||
        typeof record.jsvalue_representation.nan_boxing !== 'boolean'
    ) {
        errors.push('JSValue representation metadata is missing or invalid');
    }
    if (
        !record.phases ||
        !Number.isFinite(record.phases.eval_total_ns) ||
        record.phases.eval_total_ns < 0
    ) {
        errors.push('phases.eval_total_ns is missing or invalid');
    }
    if (!record.resources || typeof record.resources !== 'object') {
        errors.push('resources metadata is missing');
    }
    if (
        !record.steady_execute ||
        !Array.isArray(record.steady_execute.samples_ns) ||
        record.steady_execute.samples_ns.length !== iterations
    ) {
        errors.push(`steady_execute.samples_ns must contain ${iterations} samples`);
    }
    if (
        !record.steady_execute ||
        !Number.isFinite(record.steady_execute.median_ns) ||
        record.steady_execute.median_ns < 0
    ) {
        errors.push('steady_execute.median_ns is missing or invalid');
    }
    return errors;
}

const invocationLog = [];

function runHarness(
    engine,
    harness,
    caseName,
    iterations,
    warmup,
    options = {},
) {
    const sourcePath = options.sourcePath || caseSourcePath(caseName);
    const harnessArgs = [
        '--case',
        caseName,
        '--source',
        sourcePath,
        '--iterations',
        String(iterations),
        '--warmup',
        String(warmup),
        '--teardown',
        config.teardown,
    ];
    const result = spawnSync(
        'taskset',
        ['-c', String(config.cpu), harness, ...harnessArgs],
        {
            cwd: repoRoot,
            encoding: 'utf8',
            maxBuffer: 128 * 1024 * 1024,
        },
    );
    const errors = [];
    if (result.error) errors.push(`spawn failed: ${result.error.message}`);
    if (result.status !== 0) {
        errors.push(
            result.status == null
                ? `terminated by signal ${result.signal || 'unknown'}`
                : `exited with status ${result.status}`,
        );
    }
    if (result.stderr && result.stderr.length > 0) {
        errors.push('stderr was not empty');
    }
    let parsedRecord = null;
    let parseError = null;
    try {
        parsedRecord = JSON.parse(result.stdout);
    } catch (error) {
        parseError = error.message;
        errors.push(`stdout was not valid JSON: ${error.message}`);
    }
    const schemaErrors = parsedRecord
        ? validateHarnessRecord(
            parsedRecord,
            engine,
            caseName,
            iterations,
            warmup,
        )
        : [];
    errors.push(...schemaErrors);

    const stdoutValidation = {
        nonempty: Boolean(result.stdout && result.stdout.length > 0),
        json_parse_ok: parseError == null,
        record_schema_ok: schemaErrors.length === 0 && parsedRecord != null,
        parse_error: parseError,
        bytes: result.stdout ? Buffer.byteLength(result.stdout) : 0,
    };
    const stderrValidation = {
        empty: !result.stderr || result.stderr.length === 0,
        bytes: result.stderr ? Buffer.byteLength(result.stderr) : 0,
        preview:
            result.stderr && result.stderr.length > 0
                ? result.stderr.slice(0, 4096)
                : null,
    };
    const record =
        parsedRecord && typeof parsedRecord === 'object'
            ? {
                ...parsedRecord,
                harness_exit_code: result.status,
                stdout_validation: stdoutValidation,
                stderr_validation: stderrValidation,
            }
            : parsedRecord;
    const validation = {
        kind: 'harness',
        purpose: options.purpose || 'timed-sample',
        engine,
        case: caseName,
        exit_code: result.status,
        signal: result.signal || null,
        stdout: stdoutValidation,
        stderr: stderrValidation,
        passed: errors.length === 0,
        errors,
        stdout_preview:
            parseError && result.stdout ? result.stdout.slice(0, 4096) : null,
    };
    invocationLog.push(validation);
    return {
        ok: errors.length === 0,
        record,
        validation,
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

function ratioStats(ratios) {
    const valid = ratios.filter((value) => Number.isFinite(value) && value >= 0);
    if (valid.length === 0) return null;
    const sorted = [...valid].sort((left, right) => left - right);
    return {
        samples: valid,
        p25: quantile(sorted, 0.25),
        median: quantile(sorted, 0.5),
        p75: quantile(sorted, 0.75),
    };
}

function numericStats(values) {
    const valid = values.filter(
        (value) => Number.isFinite(value) && value >= 0,
    );
    if (valid.length === 0) return null;
    const sorted = [...valid].sort((left, right) => left - right);
    return {
        samples: valid,
        p25: quantile(sorted, 0.25),
        median: quantile(sorted, 0.5),
        p75: quantile(sorted, 0.75),
    };
}

const phaseComparability = {
    context_create_ns: {
        comparable: false,
        reason: 'QuickJS reports JS_NewContextRaw only, while zjs JSContext.create includes standard-global installation; raw values must not be divided.',
        note: 'The installed global surfaces also differ; see environment.global_surface.',
    },
    globals_install_ns: {
        comparable: false,
        reason: 'QuickJS exposes a separate intrinsic-install phase; zjs merges it into JSContext.create and reports null.',
        note: 'The installed global surfaces also differ; see environment.global_surface.',
    },
    compile_ns: {
        comparable: false,
        reason: 'zjs parse_ns excludes src/exec/eval_entry.zig:118-128 (contextGlobal plus createRootBytecodeFunctionObject); it cannot be divided by QuickJS JS_Eval(COMPILE_ONLY).',
        note: 'Use eval_total_ns for the cross-engine compile-plus-first-execute boundary.',
    },
    first_execute_ns: {
        comparable: false,
        reason: 'zjs vm_run_ns starts after src/exec/eval_entry.zig:118-128 (contextGlobal plus createRootBytecodeFunctionObject); it cannot be divided by QuickJS JS_EvalFunction.',
        note: 'Use eval_total_ns for the cross-engine compile-plus-first-execute boundary.',
    },
    context_plus_globals_ns: {
        comparable: true,
        reason: null,
        note: 'Derived as context_create_ns + (globals_install_ns ?? 0) on each engine. Timing boundaries align, but installed global surfaces differ; see environment.global_surface.',
    },
    eval_total_ns: {
        comparable: true,
        reason: null,
        note: 'Complete outer eval boundary on both engines; this is the only published cross-engine compile-plus-first-execute ratio.',
    },
};

function phaseValue(record, name) {
    if (name === 'context_plus_globals_ns') {
        const context = record.phases.context_create_ns;
        const globals = record.phases.globals_install_ns;
        if (!Number.isFinite(context)) return null;
        return context + (Number.isFinite(globals) ? globals : 0);
    }
    return record.phases[name];
}

function phaseStatistics(name, pairs) {
    const qjsValues = [];
    const zjsValues = [];
    const ratios = [];
    let belowResolution = false;
    for (const pair of pairs) {
        const qjs = phaseValue(pair.qjs, name);
        const zjs = phaseValue(pair.zjs, name);
        if (Number.isFinite(qjs) && qjs >= 0) qjsValues.push(qjs);
        if (Number.isFinite(zjs) && zjs >= 0) zjsValues.push(zjs);
        if (
            Number.isFinite(qjs) &&
            qjs > 0 &&
            Number.isFinite(zjs) &&
            zjs >= 0
        ) {
            if (qjs < phaseRatioFloorNs || zjs < phaseRatioFloorNs) {
                belowResolution = true;
            } else {
                ratios.push(zjs / qjs);
            }
        }
    }
    const metadata = phaseComparability[name] || {
        comparable: false,
        reason: `phase ${name} is not registered in phaseComparability; an unchecked phase cannot publish a cross-engine ratio`,
        note: 'Add an explicit phase definition only after its two timing boundaries have been reviewed.',
    };
    let reason = metadata.reason;
    if (metadata.comparable && belowResolution) {
        reason = `ratio suppressed because at least one matched value was below phase_ratio_floor_ns=${phaseRatioFloorNs}`;
    }
    return {
        comparable: metadata.comparable,
        reason,
        note: metadata.note,
        below_resolution: belowResolution,
        ratio_floor_ns: phaseRatioFloorNs,
        stats:
            metadata.comparable && !belowResolution
                ? ratioStats(ratios)
                : null,
        raw_stats_ns: {
            qjs: numericStats(qjsValues),
            zjs: numericStats(zjsValues),
        },
    };
}

function resourceStatistics(pairs) {
    const definitions = {
        allocation_count: {
            comparable: false,
            reason: 'qjs uses JSMemoryUsage.malloc_count; zjs uses JSRuntime.memoryUsage().allocation_count, whose ReleaseFast diagnostic counter is unavailable.',
        },
        allocated_bytes: {
            comparable: false,
            reason: 'qjs malloc_size and zjs MemoryUsage.allocated_bytes use different allocator accounting definitions.',
        },
        peak_rss_bytes: {
            comparable: true,
            reason: null,
        },
    };
    const output = {};
    for (const [name, metadata] of Object.entries(definitions)) {
        const qjsValues = [];
        const zjsValues = [];
        const ratios = [];
        for (const pair of pairs) {
            const qjs = pair.qjs.resources?.[name];
            const zjs = pair.zjs.resources?.[name];
            if (Number.isFinite(qjs) && qjs >= 0) qjsValues.push(qjs);
            if (Number.isFinite(zjs) && zjs >= 0) zjsValues.push(zjs);
            if (
                metadata.comparable &&
                Number.isFinite(qjs) &&
                qjs > 0 &&
                Number.isFinite(zjs) &&
                zjs >= 0
            ) {
                ratios.push(zjs / qjs);
            }
        }
        output[name] = {
            comparable: metadata.comparable,
            reason: metadata.reason,
            stats: metadata.comparable ? ratioStats(ratios) : null,
            raw_stats: {
                qjs: numericStats(qjsValues),
                zjs: numericStats(zjsValues),
            },
        };
    }
    return output;
}

function pairedStatistics(pairs) {
    const steadyRatios = pairs.map(
        (pair) =>
            pair.zjs.steady_execute.median_ns /
            pair.qjs.steady_execute.median_ns,
    );
    const phaseNames = new Set();
    for (const pair of pairs) {
        for (const name of Object.keys(pair.qjs.phases)) phaseNames.add(name);
        for (const name of Object.keys(pair.zjs.phases)) phaseNames.add(name);
    }
    phaseNames.add('context_plus_globals_ns');
    const phases = {};
    for (const name of [...phaseNames].sort()) {
        phases[name] = phaseStatistics(name, pairs);
    }
    return {
        ratio_definition: 'zjs/qjs within each matched sample pair',
        steady_execute_median_ns: ratioStats(steadyRatios),
        phases,
        resources: resourceStatistics(pairs),
    };
}

function caseDescription(caseName, sourcePath) {
    const canonical = caseMetadata[caseName];
    if (canonical && !config.caseSources.has(caseName)) {
        return { ...canonical, canonical_source: true };
    }
    if (canonical) {
        // Keeping the canonical provenance text here would let a substituted
        // workload masquerade as the checked-in P0 sentinel in the artifact.
        return {
            case_shape: 'overridden',
            canonical_source: false,
            provenance:
                `--case-source replaced the checked-in ${caseName} workload with ${sourcePath}; ` +
                'the canonical P0 sentinel description does not apply and this result must not be ' +
                'read as a P0 sentinel measurement.',
        };
    }
    return {
        case_shape: 'custom',
        canonical_source: false,
        provenance: `Custom same-runtime source supplied from ${sourcePath}; it is not part of the fixed P0 sentinel set.`,
    };
}

function invocationArtifact(invocation) {
    return {
        ...invocation.validation,
        record: invocation.record,
    };
}

function baseCaseFields(caseName, sourcePath, sourceSha256) {
    const checksumRequirement = checksumRequirementForCase(caseName);
    return {
        name: caseName,
        source_path: sourcePath,
        source_sha256: sourceSha256,
        checksum_required: checksumRequirement.required,
        checksum_requirement_declared: checksumRequirement.declared,
        ...caseDescription(caseName, sourcePath),
    };
}

function invalidResult(
    caseName,
    sourcePath,
    sourceSha256,
    validation,
    pairs,
    reason,
) {
    return {
        ...baseCaseFields(caseName, sourcePath, sourceSha256),
        status: 'invalid',
        reason,
        validation,
        sample_pairs: pairs,
        pmu: null,
        paired_ratios: null,
    };
}

function mismatchResult(
    caseName,
    sourcePath,
    sourceSha256,
    validation,
    pairs,
    reason,
) {
    return {
        ...baseCaseFields(caseName, sourcePath, sourceSha256),
        status: 'mismatch',
        reason,
        result_checksums: {
            qjs: validation.qjs.record?.result_checksum ?? null,
            zjs: validation.zjs.record?.result_checksum ?? null,
        },
        validation,
        sample_pairs: pairs,
        pmu: null,
        paired_ratios: null,
    };
}

function emptyPmuEngine(reason) {
    return {
        instructions: null,
        cycles: null,
        branches: null,
        branch_misses: null,
        reasons: {
            instructions: reason,
            cycles: reason,
            branches: reason,
            branch_misses: reason,
        },
        perf_exit_code: null,
        harness_record_valid: null,
        binding_reliable: null,
        binding_reason: reason,
        raw_events: {},
    };
}

function normalizedPmuKey(eventName) {
    for (const name of pmuEvents) {
        if (
            eventName === name ||
            eventName.endsWith(`/${name}/`) ||
            eventName.includes(`/${name}/`)
        ) {
            return name === 'branch-misses' ? 'branch_misses' : name;
        }
    }
    return null;
}

function parsePerfCounters(stderr, expectedPmuName) {
    const values = {
        instructions: [],
        cycles: [],
        branches: [],
        branch_misses: [],
    };
    const unavailable = {
        instructions: [],
        cycles: [],
        branches: [],
        branch_misses: [],
    };
    for (const line of stderr.split(/\r?\n/)) {
        const columns = line.split(',');
        if (columns.length < 3) continue;
        const key = normalizedPmuKey(columns[2].trim());
        if (!key) continue;
        const rawValue = columns[0].trim();
        if (
            rawValue === '<not counted>' ||
            rawValue === '<not supported>'
        ) {
            unavailable[key].push(rawValue);
            continue;
        }
        const value = Number(rawValue.replace(/\s+/g, ''));
        if (Number.isFinite(value) && value >= 0) {
            values[key].push({
                value,
                event: columns[2].trim(),
                counter_runtime_ns:
                    columns.length > 3 && columns[3].trim().length > 0
                        ? Number(columns[3].trim())
                        : null,
                run_percent:
                    columns.length > 4 && columns[4].trim().length > 0
                        ? Number(columns[4].trim())
                        : null,
            });
        }
    }

    const counters = {};
    const reasons = {};
    const bindingReasons = [];
    for (const key of Object.keys(values)) {
        if (values[key].length === 1) {
            const selected = values[key][0];
            counters[key] = selected.value;
            reasons[key] = null;
            if (
                expectedPmuName == null ||
                !selected.event.startsWith(`${expectedPmuName}/`)
            ) {
                bindingReasons.push(
                    `${key} selected ${selected.event}, expected ${expectedPmuName || 'a discovered single PMU'}`,
                );
            }
        } else if (values[key].length > 1) {
            counters[key] = null;
            reasons[key] =
                `multiple counted PMU rows (${values[key].length}); refusing to sum across PMUs`;
            bindingReasons.push(`${key}: ${reasons[key]}`);
        } else {
            counters[key] = null;
            reasons[key] =
                unavailable[key].length > 0
                    ? `all matching PMU rows had no data: ${[...new Set(unavailable[key])].join(', ')}`
                    : 'perf stat emitted no matching counter row';
        }
    }
    if (values.instructions.length !== 1) {
        bindingReasons.push(
            `instructions had ${values.instructions.length} counted rows; exactly one is required`,
        );
    }
    return {
        counters,
        reasons,
        raw_events: values,
        binding_reliable: bindingReasons.length === 0,
        binding_reason:
            bindingReasons.length === 0
                ? null
                : [...new Set(bindingReasons)].join('; '),
    };
}

function runPmu(engine, harness, caseName, sourcePath) {
    if (!config.pmu) {
        return emptyPmuEngine('disabled by --no-pmu');
    }
    const harnessArgs = [
        '--case',
        caseName,
        '--source',
        sourcePath,
        '--iterations',
        String(config.iterations),
        '--warmup',
        String(config.warmup),
        '--teardown',
        config.teardown,
    ];
    const requestedPmuEvents = config.selectedPmu
        ? pmuEvents.map((event) => `${config.selectedPmu}/${event}/`)
        : pmuEvents;
    const result = spawnSync(
        'taskset',
        [
            '-c',
            String(config.cpu),
            'perf',
            'stat',
            '-x,',
            '-e',
            requestedPmuEvents.join(','),
            '--',
            harness,
            ...harnessArgs,
        ],
        {
            cwd: repoRoot,
            encoding: 'utf8',
            maxBuffer: 128 * 1024 * 1024,
        },
    );
    const errors = [];
    if (result.error) errors.push(`spawn failed: ${result.error.message}`);
    if (result.status !== 0) {
        errors.push(
            result.status == null
                ? `terminated by signal ${result.signal || 'unknown'}`
                : `exited with status ${result.status}`,
        );
    }
    let record = null;
    try {
        record = JSON.parse(result.stdout);
    } catch (error) {
        errors.push(`harness stdout was not valid JSON: ${error.message}`);
    }
    const schemaErrors = record
        ? validateHarnessRecord(
            record,
            engine,
            caseName,
            config.iterations,
            config.warmup,
        )
        : [];
    errors.push(...schemaErrors);
    const parsed = parsePerfCounters(
        result.stderr || '',
        config.selectedPmu,
    );
    if (!parsed.binding_reliable) {
        errors.push(`PMU binding is not reliable: ${parsed.binding_reason}`);
    }
    if (errors.length > 0) {
        for (const key of Object.keys(parsed.counters)) {
            parsed.counters[key] = null;
            parsed.reasons[key] = `PMU invocation invalid: ${errors.join('; ')}`;
        }
    }
    const validation = {
        kind: 'pmu',
        purpose: 'separate-perf-stat',
        engine,
        case: caseName,
        exit_code: result.status,
        signal: result.signal || null,
        stdout_json_ok: record != null,
        harness_record_valid: schemaErrors.length === 0 && record != null,
        passed: errors.length === 0,
        errors,
    };
    invocationLog.push(validation);
    const bindingReliable =
        parsed.binding_reliable && errors.length === 0;
    return {
        instructions: parsed.counters.instructions,
        cycles: parsed.counters.cycles,
        branches: parsed.counters.branches,
        branch_misses: parsed.counters.branch_misses,
        reasons: parsed.reasons,
        perf_exit_code: result.status,
        harness_record_valid: validation.harness_record_valid,
        binding_reliable: bindingReliable,
        binding_reason: bindingReliable
            ? null
            : [
                parsed.binding_reason,
                ...errors,
            ]
                .filter(Boolean)
                .join('; ') || 'PMU invocation was not fully validated',
        raw_events: parsed.raw_events,
    };
}

function pmuForCase(caseName, sourcePath) {
    if (config.pmu) {
        console.error(`[${caseName}] collecting separate PMU samples`);
    }
    const qjs = runPmu('qjs', config.qjsHarness, caseName, sourcePath);
    const zjs = runPmu('zjs', config.zjsHarness, caseName, sourcePath);
    const ratios = {};
    const reasons = {};
    for (const key of [
        'instructions',
        'cycles',
        'branches',
        'branch_misses',
    ]) {
        if (
            Number.isFinite(qjs[key]) &&
            qjs[key] > 0 &&
            Number.isFinite(zjs[key]) &&
            zjs[key] >= 0
        ) {
            ratios[key] = zjs[key] / qjs[key];
            reasons[key] = null;
        } else {
            ratios[key] = null;
            reasons[key] = [
                qjs.reasons[key] ? `qjs: ${qjs.reasons[key]}` : null,
                zjs.reasons[key] ? `zjs: ${zjs.reasons[key]}` : null,
            ]
                .filter(Boolean)
                .join('; ') || 'counter ratio unavailable';
        }
    }
    ratios.reasons = reasons;
    const bindingReliable =
        !config.pmu ||
        (qjs.binding_reliable === true && zjs.binding_reliable === true);
    return {
        qjs,
        zjs,
        ratios,
        binding_reliable: bindingReliable,
        binding_reason: bindingReliable
            ? null
            : [
                qjs.binding_reason ? `qjs: ${qjs.binding_reason}` : null,
                zjs.binding_reason ? `zjs: ${zjs.binding_reason}` : null,
            ]
                .filter(Boolean)
                .join('; ') || 'PMU binding was not checked',
    };
}

function runCase(caseName) {
    const sourcePath = caseSourcePath(caseName);
    const expectedSourceSha256 = sha256File(sourcePath);
    console.error(`[${caseName}] validating checksums`);
    const preflight = {
        qjs: runHarness('qjs', config.qjsHarness, caseName, 1, 0, {
            sourcePath,
            purpose: 'preflight',
        }),
        zjs: runHarness('zjs', config.zjsHarness, caseName, 1, 0, {
            sourcePath,
            purpose: 'preflight',
        }),
    };
    const validation = {
        qjs: invocationArtifact(preflight.qjs),
        zjs: invocationArtifact(preflight.zjs),
    };
    if (!preflight.qjs.ok || !preflight.zjs.ok) {
        return invalidResult(
            caseName,
            sourcePath,
            expectedSourceSha256,
            validation,
            [],
            [
                ...preflight.qjs.validation.errors.map((item) => `qjs: ${item}`),
                ...preflight.zjs.validation.errors.map((item) => `zjs: ${item}`),
            ].join('; '),
        );
    }
    for (const engine of ['qjs', 'zjs']) {
        if (
            preflight[engine].record.source_sha256 !== expectedSourceSha256
        ) {
            return invalidResult(
                caseName,
                sourcePath,
                expectedSourceSha256,
                validation,
                [],
                `${engine} source SHA-256 mismatch: expected ${expectedSourceSha256}, got ${preflight[engine].record.source_sha256}`,
            );
        }
    }
    if (
        preflight.qjs.record.result_checksum !==
        preflight.zjs.record.result_checksum
    ) {
        return mismatchResult(
            caseName,
            sourcePath,
            expectedSourceSha256,
            validation,
            [],
            'preflight result checksum mismatch',
        );
    }

    const pairs = [];
    for (let sampleIndex = 0; sampleIndex < config.samples; sampleIndex += 1) {
        const qjsFirst = sampleIndex % 2 === 0;
        const order = qjsFirst ? ['qjs', 'zjs'] : ['zjs', 'qjs'];
        console.error(
            `[${caseName}] sample ${sampleIndex + 1}/${config.samples} ${order.join('->')}`,
        );
        const pair = {
            sample_index: sampleIndex,
            order: order.join('->'),
            harness_validation: {},
        };
        for (const engine of order) {
            const invocation = runHarness(
                engine,
                engine === 'qjs' ? config.qjsHarness : config.zjsHarness,
                caseName,
                config.iterations,
                config.warmup,
                {
                    sourcePath,
                    purpose: `sample-${sampleIndex}`,
                },
            );
            pair[engine] = invocation.record;
            pair.harness_validation[engine] = invocation.validation;
            if (!invocation.ok) {
                pairs.push(pair);
                return invalidResult(
                    caseName,
                    sourcePath,
                    expectedSourceSha256,
                    validation,
                    pairs,
                    `${engine} sample ${sampleIndex} invalid: ${invocation.validation.errors.join('; ')}`,
                );
            }
        }
        pairs.push(pair);
        if (
            pair.qjs.source_sha256 !== expectedSourceSha256 ||
            pair.zjs.source_sha256 !== expectedSourceSha256
        ) {
            return invalidResult(
                caseName,
                sourcePath,
                expectedSourceSha256,
                validation,
                pairs,
                `sample ${sampleIndex} source SHA-256 mismatch`,
            );
        }
        if (pair.qjs.result_checksum !== pair.zjs.result_checksum) {
            return mismatchResult(
                caseName,
                sourcePath,
                expectedSourceSha256,
                validation,
                pairs,
                `result checksum mismatch in sample ${sampleIndex}`,
            );
        }
    }

    return {
        ...baseCaseFields(caseName, sourcePath, expectedSourceSha256),
        status: 'ok',
        result_checksum: preflight.qjs.record.result_checksum,
        validation,
        sample_pairs: pairs,
        pmu: pmuForCase(caseName, sourcePath),
        paired_ratios: pairedStatistics(pairs),
    };
}

function comparabilityComponent(reasons, extra = {}) {
    const uniqueReasons = [...new Set(reasons.filter(Boolean))];
    return {
        comparable: uniqueReasons.length === 0,
        reason:
            uniqueReasons.length === 0 ? null : uniqueReasons.join('; '),
        ...extra,
    };
}

function caseInvocationPairs(item) {
    const pairs = [];
    const preflightQjs = item.validation?.qjs?.record ?? null;
    const preflightZjs = item.validation?.zjs?.record ?? null;
    pairs.push({
        label: 'preflight',
        qjs: preflightQjs,
        zjs: preflightZjs,
    });
    for (const [index, pair] of (item.sample_pairs || []).entries()) {
        pairs.push({
            label: `sample ${index + 1}`,
            qjs: pair.qjs ?? null,
            zjs: pair.zjs ?? null,
        });
    }
    return pairs;
}

function sourceComparability(item) {
    const reasons = [];
    const definition = caseMetadata[item.name];
    if (!definition) {
        reasons.push(
            `case ${item.name} is not registered in caseMetadata`,
        );
    }
    if (item.canonical_source !== true) {
        reasons.push(
            'canonical_source was not explicitly true; overridden/custom workloads are not source-comparable',
        );
    }
    if (
        typeof item.source_sha256 !== 'string' ||
        !/^[0-9a-f]{64}$/.test(item.source_sha256)
    ) {
        reasons.push('canonical source SHA-256 is missing or invalid');
    }
    const pairs = caseInvocationPairs(item);
    if (pairs.length !== config.samples + 1) {
        reasons.push(
            `source validation covered ${pairs.length - 1} timed pairs, expected ${config.samples}`,
        );
    }
    for (const pair of pairs) {
        for (const engine of ['qjs', 'zjs']) {
            const record = pair[engine];
            if (!record || typeof record !== 'object') {
                reasons.push(`${pair.label} ${engine} record is missing`);
                continue;
            }
            if (record.source_sha256 !== item.source_sha256) {
                reasons.push(
                    `${pair.label} ${engine} source SHA-256 does not match the selected source`,
                );
            }
            if (
                record.layer !== 'same-runtime' ||
                record.case !== item.name
            ) {
                reasons.push(
                    `${pair.label} ${engine} layer/case metadata does not match`,
                );
            }
        }
    }
    if (
        item.validation?.qjs?.passed !== true ||
        item.validation?.zjs?.passed !== true
    ) {
        reasons.push('preflight harness validation was not explicitly successful');
    }
    for (const [index, pair] of (item.sample_pairs || []).entries()) {
        if (
            pair.harness_validation?.qjs?.passed !== true ||
            pair.harness_validation?.zjs?.passed !== true
        ) {
            reasons.push(
                `sample ${index + 1} harness validation was not explicitly successful`,
            );
        }
    }
    return comparabilityComponent(reasons, {
        case_registered: Boolean(definition),
        canonical_source: item.canonical_source === true,
    });
}

function checksumComparability(item) {
    const requirement = checksumRequirementForCase(item.name);
    const pairs = caseInvocationPairs(item);
    const evidencePresent = pairs.some((pair) =>
        ['qjs', 'zjs'].some((engine) => {
            const value = pair[engine]?.result_checksum;
            return typeof value === 'string' && value.trim().length > 0;
        }),
    );
    const strictValidationRequired =
        requirement.required || evidencePresent;
    const reasons = [];
    const matchingValues = [];
    if (strictValidationRequired) {
        if (pairs.length !== config.samples + 1) {
            reasons.push(
                `checksum validation covered ${pairs.length - 1} timed pairs, expected ${config.samples}`,
            );
        }
        for (const pair of pairs) {
            const qjs = pair.qjs?.result_checksum;
            const zjs = pair.zjs?.result_checksum;
            if (typeof qjs !== 'string' || qjs.trim().length === 0) {
                reasons.push(`${pair.label} qjs checksum is missing or empty`);
            }
            if (typeof zjs !== 'string' || zjs.trim().length === 0) {
                reasons.push(`${pair.label} zjs checksum is missing or empty`);
            }
            if (
                typeof qjs === 'string' &&
                qjs.trim().length > 0 &&
                typeof zjs === 'string' &&
                zjs.trim().length > 0
            ) {
                if (qjs !== zjs) {
                    reasons.push(
                        `${pair.label} cross-engine checksum mismatch (qjs=${qjs} zjs=${zjs})`,
                    );
                } else {
                    matchingValues.push(qjs);
                }
            }
        }
    }
    return comparabilityComponent(reasons, {
        required: requirement.required,
        checksum_requirement_declared: requirement.declared,
        validation_mode: requirement.required
            ? 'required'
            : evidencePresent
              ? 'optional evidence validated'
              : 'explicitly not required',
        all_invocations_match:
            strictValidationRequired && pairs.length > 0
                ? matchingValues.length === pairs.length
                : null,
    });
}

function metricComparability(item) {
    const reasons = [];
    if (item.status !== 'ok') {
        reasons.push(
            `case status before comparability assessment is ${item.status}`,
        );
    }
    const stats = item.paired_ratios?.steady_execute_median_ns;
    if (!stats || typeof stats !== 'object') {
        reasons.push('steady-execute paired ratio statistics are missing');
    } else {
        if (
            !Array.isArray(stats.samples) ||
            stats.samples.length !== config.samples
        ) {
            reasons.push(
                `steady-execute ratio has ${stats.samples?.length ?? 'no'} samples, expected ${config.samples}`,
            );
        } else if (
            stats.samples.some(
                (value) => !Number.isFinite(value) || value <= 0,
            )
        ) {
            reasons.push(
                'steady-execute paired ratios contain a missing or invalid value',
            );
        }
        for (const field of ['p25', 'median', 'p75']) {
            if (!Number.isFinite(stats[field]) || stats[field] <= 0) {
                reasons.push(
                    `steady-execute paired ratio ${field} is missing or invalid`,
                );
            }
        }
    }
    return comparabilityComponent(reasons, {
        primary_metric: 'steady_execute_median_ns',
    });
}

function provenanceComparability(item, environment) {
    const expectedOrders = Array.from(
        { length: config.samples },
        (_unused, index) =>
            index % 2 === 0 ? 'qjs->zjs' : 'zjs->qjs',
    );
    const observedOrders = (item.sample_pairs || []).map(
        (pair) => pair.order,
    );
    const samplingComplete =
        observedOrders.length === expectedOrders.length &&
        observedOrders.every(
            (order, index) => order === expectedOrders[index],
        );
    const metadataComplete =
        (item.sample_pairs || []).length === config.samples &&
        (item.sample_pairs || []).every(
            (pair) =>
                pair.qjs?.iterations === config.iterations &&
                pair.zjs?.iterations === config.iterations &&
                pair.qjs?.warmup === config.warmup &&
                pair.zjs?.warmup === config.warmup,
        );
    const pmuReliable =
        !config.pmu || item.pmu?.binding_reliable === true;
    const checks = {
        case_registered: {
            passed: Boolean(caseMetadata[item.name]),
            reason: caseMetadata[item.name]
                ? null
                : `case ${item.name} is not registered in caseMetadata`,
        },
        canonical_source: {
            passed: item.canonical_source === true,
            reason:
                item.canonical_source === true
                    ? null
                    : 'canonical_source was not explicitly true',
        },
        qjs_head_matches: {
            passed: environment.qjs_git_commit === expectedQjsHead,
            reason:
                environment.qjs_git_commit === expectedQjsHead
                    ? null
                    : `observed ${environment.qjs_git_commit}, expected ${expectedQjsHead}`,
        },
        qjs_version_matches: {
            passed: environment.qjs_version === expectedQjsVersion,
            reason:
                environment.qjs_version === expectedQjsVersion
                    ? null
                    : `observed ${environment.qjs_version}, expected ${expectedQjsVersion}`,
        },
        qjs_tree_clean_before: {
            passed: environment.qjs_tree_clean_before === true,
            reason:
                environment.qjs_tree_clean_before === true
                    ? null
                    : 'pinned QuickJS tree was dirty before measurement',
        },
        qjs_tree_clean_after: {
            passed: environment.qjs_tree_clean_after === true,
            reason:
                environment.qjs_tree_clean_after === true
                    ? null
                    : 'pinned QuickJS tree became dirty during measurement',
        },
        binary_sha256_known: {
            passed:
                /^[0-9a-f]{64}$/.test(
                    environment.zjs_harness_sha256 || '',
                ) &&
                /^[0-9a-f]{64}$/.test(
                    environment.qjs_harness_sha256 || '',
                ),
            reason:
                /^[0-9a-f]{64}$/.test(
                    environment.zjs_harness_sha256 || '',
                ) &&
                /^[0-9a-f]{64}$/.test(
                    environment.qjs_harness_sha256 || '',
                )
                    ? null
                    : 'one or more harness SHA-256 values are missing',
        },
        taskset_binding_succeeded: {
            passed: environment.taskset_binding_probe?.passed === true,
            reason:
                environment.taskset_binding_probe?.passed === true
                    ? null
                    : environment.taskset_binding_probe?.reason ||
                      'taskset affinity was not checked',
        },
        sampling_abba_complete: {
            passed: samplingComplete,
            reason: samplingComplete
                ? null
                : `observed sampling order ${JSON.stringify(observedOrders)}, expected ${JSON.stringify(expectedOrders)}`,
        },
        metadata_complete: {
            passed: metadataComplete,
            reason: metadataComplete
                ? null
                : 'iterations/warmup metadata is missing or incomplete',
        },
        pmu_binding_reliable: {
            passed: pmuReliable,
            reason: pmuReliable
                ? null
                : item.pmu?.binding_reason ||
                  environment.pmu.binding_probe?.reason ||
                  'requested PMU was not reliably bound',
        },
    };
    const reasons = Object.entries(checks)
        .filter(([_name, check]) => check.passed !== true)
        .map(([name, check]) => `${name}: ${check.reason}`);
    return comparabilityComponent(reasons, { checks });
}

function applyCaseComparability(item, environment) {
    const components = {
        source: sourceComparability(item),
        checksum: checksumComparability(item),
        metric: metricComparability(item),
        provenance: provenanceComparability(item, environment),
    };
    const comparable = Object.values(components).every(
        (component) => component.comparable === true,
    );
    const componentFailures = Object.entries(components)
        .filter(([_name, component]) => component.comparable !== true)
        .map(
            ([name, component]) =>
                `${name}_comparable: ${component.reason || 'false'}`,
        );
    const originalStatus = item.status;
    const status =
        originalStatus === 'ok' && !comparable ? 'invalid' : originalStatus;
    const reason =
        status === 'invalid' && originalStatus === 'ok'
            ? componentFailures.join('; ')
            : item.reason ?? null;
    return {
        ...item,
        status,
        status_before_comparability: originalStatus,
        reason,
        comparable,
        comparability: {
            formula:
                'source_comparable && checksum_comparable && metric_comparable && provenance_comparable',
            ...components,
        },
        source_comparable: components.source.comparable,
        source_comparable_reason: components.source.reason,
        checksum_comparable: components.checksum.comparable,
        checksum_comparable_reason: components.checksum.reason,
        metric_comparable: components.metric.comparable,
        metric_comparable_reason: components.metric.reason,
        provenance_comparable: components.provenance.comparable,
        provenance_comparable_reason: components.provenance.reason,
        checksum_required: components.checksum.required,
        checksum_requirement_declared:
            components.checksum.checksum_requirement_declared,
    };
}

function parseCpuInfo() {
    const blocks = fs
        .readFileSync('/proc/cpuinfo', 'utf8')
        .trim()
        .split(/\n\s*\n/);
    return blocks.map((block) => {
        const fields = {};
        for (const line of block.split(/\r?\n/)) {
            const separator = line.indexOf(':');
            if (separator < 0) continue;
            fields[line.slice(0, separator).trim()] = line
                .slice(separator + 1)
                .trim();
        }
        return fields;
    });
}

function collectCpuMetadata() {
    const lscpuText = runCommand('lscpu', [
        '-p=CPU,MODELNAME,CORE,SOCKET,MAXMHZ,MINMHZ',
    ]);
    const rows = lscpuText
        .split(/\r?\n/)
        .filter((line) => line.length > 0 && !line.startsWith('#'))
        .map((line) => {
            const [cpu, model, core, socket, maxMhz, minMhz] =
                line.split(',');
            return {
                cpu: Number(cpu),
                model,
                core: Number(core),
                socket: Number(socket),
                max_mhz: Number(maxMhz),
                min_mhz: Number(minMhz),
            };
        });
    const cpuInfo = parseCpuInfo();
    const boundRow = rows.find((row) => row.cpu === config.cpu) || null;
    const boundInfo =
        cpuInfo.find((fields) => Number(fields.processor) === config.cpu) ||
        null;
    const modelGroups = [];
    for (const model of [...new Set(rows.map((row) => row.model))].sort()) {
        modelGroups.push({
            model,
            cpus: rows
                .filter((row) => row.model === model)
                .map((row) => row.cpu),
        });
    }
    const implementerParts = [
        ...new Set(
            cpuInfo
                .map((fields) =>
                    fields['CPU implementer'] && fields['CPU part']
                        ? `${fields['CPU implementer']}/${fields['CPU part']}`
                        : null,
                )
                .filter(Boolean),
        ),
    ].sort();
    return {
        source: 'lscpu -p plus /proc/cpuinfo; node os.cpus() is not used',
        fixed_cpu_id: config.cpu,
        distinct_models: modelGroups,
        distinct_implementer_parts: implementerParts,
        bound_cpu: {
            id: config.cpu,
            model: boundRow?.model ?? null,
            core: boundRow?.core ?? null,
            socket: boundRow?.socket ?? null,
            max_mhz: boundRow?.max_mhz ?? null,
            min_mhz: boundRow?.min_mhz ?? null,
            cpu_implementer: boundInfo?.['CPU implementer'] ?? null,
            cpu_part: boundInfo?.['CPU part'] ?? null,
            cpu_variant: boundInfo?.['CPU variant'] ?? null,
            cpu_revision: boundInfo?.['CPU revision'] ?? null,
        },
    };
}

function probeGlobalSurface() {
    const tempDir = fs.mkdtempSync(
        path.join(os.tmpdir(), 'zjs-same-runtime-global-surface-'),
    );
    const sourcePath = path.join(tempDir, 'global_surface.js');
    const caseName = '__global_surface_probe__';
    fs.writeFileSync(
        sourcePath,
        'function run() { return Object.getOwnPropertyNames(globalThis).sort().join(\',\'); }\n',
    );
    try {
        const qjs = runHarness(
            'qjs',
            config.qjsHarness,
            caseName,
            1,
            0,
            { sourcePath, purpose: 'global-surface-probe' },
        );
        const zjs = runHarness(
            'zjs',
            config.zjsHarness,
            caseName,
            1,
            0,
            { sourcePath, purpose: 'global-surface-probe' },
        );
        const validation = {
            qjs: invocationArtifact(qjs),
            zjs: invocationArtifact(zjs),
        };
        if (!qjs.ok || !zjs.ok) {
            return {
                status: 'incomplete',
                reason: [
                    ...qjs.validation.errors.map((item) => `qjs: ${item}`),
                    ...zjs.validation.errors.map((item) => `zjs: ${item}`),
                ].join('; '),
                zjs_count: null,
                qjs_count: null,
                zjs_only: [],
                qjs_only: [],
                validation,
            };
        }
        const qjsNames =
            qjs.record.result_checksum.length === 0
                ? []
                : qjs.record.result_checksum.split(',');
        const zjsNames =
            zjs.record.result_checksum.length === 0
                ? []
                : zjs.record.result_checksum.split(',');
        const qjsSet = new Set(qjsNames);
        const zjsSet = new Set(zjsNames);
        return {
            status: 'ok',
            reason: null,
            zjs_count: zjsNames.length,
            qjs_count: qjsNames.length,
            zjs_only: zjsNames.filter((name) => !qjsSet.has(name)),
            qjs_only: qjsNames.filter((name) => !zjsSet.has(name)),
            validation,
        };
    } finally {
        fs.unlinkSync(sourcePath);
        fs.rmdirSync(tempDir);
    }
}

function collectEnvironment() {
    const quickjsDir = process.env.QUICKJS_DIR || '/home/aneryu/quickjs';
    const qjsVersionPath = path.join(quickjsDir, 'VERSION');
    const qjsCliPath = path.join(quickjsDir, 'qjs');
    const qjsCliProbe = captureCommand(qjsCliPath, ['--help']);
    const qjsCliOutput = `${qjsCliProbe.stdout}\n${qjsCliProbe.stderr}`
        .trim()
        .split(/\r?\n/, 1)[0] || null;
    const qjsTreeStatusBefore = runCommand(
        'git',
        ['-C', quickjsDir, 'status', '--porcelain'],
    );
    const tasksetBindingProbe = probeTasksetAffinity(config.cpu);
    const pmuBindingProbe = discoverPmuForCpu(config.cpu);
    return {
        zjs_git_commit: runCommand('git', ['rev-parse', 'HEAD'], {
            cwd: repoRoot,
        }),
        qjs_git_commit: runCommand(
            'git',
            ['-C', quickjsDir, 'rev-parse', 'HEAD'],
        ),
        qjs_version: fs.readFileSync(qjsVersionPath, 'utf8').trim(),
        quickjs_dir: quickjsDir,
        qjs_tree_status_before: qjsTreeStatusBefore,
        qjs_tree_clean_before: qjsTreeStatusBefore.length === 0,
        qjs_tree_status_after: null,
        qjs_tree_clean_after: null,
        qjs_cli_version_probe: {
            path: qjsCliPath,
            first_output_line: qjsCliOutput,
            exit_code: qjsCliProbe.exit_code,
            note: 'qjs --help output is retained even when the command exits nonzero',
        },
        zjs_harness_path: config.zjsHarness,
        qjs_harness_path: config.qjsHarness,
        zjs_harness_sha256: sha256File(config.zjsHarness),
        qjs_harness_sha256: sha256File(config.qjsHarness),
        zig_version: commandFirstLine(config.zig, ['version']),
        gcc_version: commandFirstLine('gcc', ['--version']),
        uname_release: commandFirstLine('uname', ['-r']),
        kernel: runCommand('uname', ['-srvmo']),
        cpu: collectCpuMetadata(),
        fixed_cpu_id: config.cpu,
        taskset_binding_probe: tasksetBindingProbe,
        sampling: {
            warmup: config.warmup,
            timed_samples: config.samples,
            iterations_per_sample: config.iterations,
            order: 'ABBA',
        },
        phase_coverage: {
            parser: true,
            compile: true,
            context_create: true,
            globals_install_boundary: true,
            eval_total: true,
            steady_execute: true,
            teardown_phase_present: true,
            teardown_measured: config.teardown === 'leak-check',
        },
        teardown_mode: config.teardown,
        leak_check: config.teardown === 'leak-check',
        pmu: {
            enabled: config.pmu,
            separate_from_timing_samples: true,
            selected_pmu: config.selectedPmu,
            binding_probe: pmuBindingProbe,
            command_shape:
                'taskset -c <cpu> perf stat -x, -e <selected-pmu>/{instructions,cycles,branches,branch-misses}/ -- <harness> ...',
            counters: pmuEvents,
        },
    };
}

function geometricMean(values) {
    if (
        values.length === 0 ||
        values.some((value) => !Number.isFinite(value) || value <= 0)
    ) {
        return null;
    }
    return Math.exp(
        values.reduce((sum, value) => sum + Math.log(value), 0) /
            values.length,
    );
}

function aggregateMetric(cases, valueForCase, disabledReason = null) {
    const byName = new Map(cases.map((item) => [item.name, item]));
    const participants = [];
    const missingCases = [];
    const missingCaseDetails = [];
    for (const name of p0SentinelNames) {
        const item = byName.get(name);
        const value = item ? valueForCase(item) : null;
        // A P0 sentinel whose source was swapped via --case-source is no longer
        // that sentinel. Letting it participate would publish a PRD 2.3 exit-line
        // geomean computed over an arbitrary workload while still reporting
        // complete=true, which is a way to fabricate a passing exit line.
        const overriddenSource = config.caseSources.get(name) || null;
        if (
            overriddenSource == null &&
            item?.status === 'ok' &&
            Number.isFinite(value) &&
            value > 0
        ) {
            participants.push({ name, ratio: value });
        } else {
            missingCases.push(name);
            missingCaseDetails.push({
                name,
                reason: overriddenSource
                    ? `--case-source substituted ${overriddenSource} for the checked-in workload; ` +
                      'a substituted source cannot count toward the P0 sentinel aggregate'
                    : disabledReason ||
                      (!item
                          ? 'not requested'
                          : item.status !== 'ok'
                            ? `case status is ${item.status}`
                            : 'metric unavailable'),
            });
        }
    }
    const complete = missingCases.length === 0;
    const partialValues = participants.map((item) => item.ratio);
    return {
        status: disabledReason
            ? 'disabled'
            : complete
              ? 'complete'
              : 'incomplete',
        complete,
        missing_cases: missingCases,
        missing_case_details: missingCaseDetails,
        p0_sentinel_geomean: complete
            ? geometricMean(partialValues)
            : null,
        partial_geomean:
            !complete && partialValues.length > 0
                ? geometricMean(partialValues)
                : null,
        partial_cases: complete
            ? []
            : participants.map((item) => item.name),
        participants,
    };
}

function buildAggregate(cases) {
    const steady = aggregateMetric(
        cases,
        (item) => item.paired_ratios?.steady_execute_median_ns?.median,
    );
    const maxParticipant =
        steady.complete && steady.participants.length > 0
            ? steady.participants.reduce((maximum, item) =>
                item.ratio > maximum.ratio ? item : maximum,
            )
            : null;
    const partialMaxParticipant =
        !steady.complete && steady.participants.length > 0
            ? steady.participants.reduce((maximum, item) =>
                item.ratio > maximum.ratio ? item : maximum,
            )
            : null;
    const overLimitCases = steady.participants
        .filter(
            (item) =>
                item.ratio > sameRuntimePolicy.exit_line.per_case_limit,
        )
        .map((item) => ({ name: item.name, ratio: item.ratio }));
    const instructions = aggregateMetric(
        cases,
        (item) => item.pmu?.ratios?.instructions,
        config.pmu ? null : 'disabled by --no-pmu',
    );
    return {
        status: steady.status,
        complete: steady.complete,
        missing_cases: steady.missing_cases,
        missing_case_details: steady.missing_case_details,
        p0_sentinel_geomean: steady.p0_sentinel_geomean,
        partial_geomean: steady.partial_geomean,
        partial_cases: steady.partial_cases,
        max_case_ratio: maxParticipant?.ratio ?? null,
        max_case_name: maxParticipant?.name ?? null,
        partial_max_case_ratio: partialMaxParticipant?.ratio ?? null,
        partial_max_case_name: partialMaxParticipant?.name ?? null,
        exit_line: {
            geomean_limit: sameRuntimePolicy.exit_line.geomean_limit,
            per_case_limit: sameRuntimePolicy.exit_line.per_case_limit,
            geomean_pass:
                steady.complete &&
                steady.p0_sentinel_geomean <=
                    sameRuntimePolicy.exit_line.geomean_limit,
            per_case_pass:
                steady.complete && overLimitCases.length === 0,
            over_limit_cases: overLimitCases,
        },
        pmu: {
            instructions,
        },
    };
}

function summarizeValidation() {
    const harnessInvocations = invocationLog.filter(
        (item) => item.kind === 'harness',
    );
    return {
        invocation_count: invocationLog.length,
        harness_invocation_count: harnessInvocations.length,
        exit_codes: invocationLog.map((item) => ({
            kind: item.kind,
            purpose: item.purpose,
            engine: item.engine,
            case: item.case,
            exit_code: item.exit_code,
            signal: item.signal,
        })),
        all_exit_codes_zero: invocationLog.every(
            (item) => item.exit_code === 0,
        ),
        stdout: {
            all_harness_json_valid: harnessInvocations.every(
                (item) =>
                    item.stdout?.json_parse_ok &&
                    item.stdout?.record_schema_ok,
            ),
            invalid_count: harnessInvocations.filter(
                (item) =>
                    !item.stdout?.json_parse_ok ||
                    !item.stdout?.record_schema_ok,
            ).length,
        },
        stderr: {
            all_harness_stderr_empty: harnessInvocations.every(
                (item) => item.stderr?.empty,
            ),
            nonempty_count: harnessInvocations.filter(
                (item) => !item.stderr?.empty,
            ).length,
        },
        all_validations_passed: invocationLog.every((item) => item.passed),
    };
}

parseArgs();
for (const harness of [config.zjsHarness, config.qjsHarness]) {
    if (!fs.existsSync(harness)) fail(`harness does not exist: ${harness}`);
}
const initialPmuBindingProbe = discoverPmuForCpu(config.cpu);
config.selectedPmu =
    initialPmuBindingProbe.passed === true
        ? initialPmuBindingProbe.name
        : null;

const startedAt = new Date().toISOString();
const environment = collectEnvironment();
environment.global_surface = probeGlobalSurface();
environment.build_mode = {
    zjs:
        environment.global_surface.validation?.zjs?.record?.build ?? null,
    qjs:
        environment.global_surface.validation?.qjs?.record?.build ?? null,
};
environment.jsvalue_representation = {
    zjs:
        environment.global_surface.validation?.zjs?.record
            ?.jsvalue_representation ?? null,
    qjs:
        environment.global_surface.validation?.qjs?.record
            ?.jsvalue_representation ?? null,
};
environment.clock_monotonic_resolution_ns = {
    zjs:
        environment.global_surface.validation?.zjs?.record
            ?.clock_monotonic_resolution_ns ?? null,
    qjs:
        environment.global_surface.validation?.qjs?.record
            ?.clock_monotonic_resolution_ns ?? null,
};
environment.resource_sources = {
    zjs:
        environment.global_surface.validation?.zjs?.record?.resources ??
        null,
    qjs:
        environment.global_surface.validation?.qjs?.record?.resources ??
        null,
};
const rawCases = config.cases.map(runCase);
environment.qjs_tree_status_after = runCommand(
    'git',
    ['-C', environment.quickjs_dir, 'status', '--porcelain'],
);
environment.qjs_tree_clean_after =
    environment.qjs_tree_status_after.length === 0;
const cases = rawCases.map((item) =>
    applyCaseComparability(item, environment),
);
const aggregate = buildAggregate(cases);
environment.validation = summarizeValidation();
const summary = {
    tool: 'dual-engine-same-runtime',
    layer: 'same-runtime',
    timestamp: startedAt,
    sampling_order: 'ABBA',
    teardown_mode: config.teardown,
    cpu: config.cpu,
    iterations: config.iterations,
    warmup: config.warmup,
    samples: config.samples,
    phase_ratio_floor_ns: phaseRatioFloorNs,
    pmu_enabled: config.pmu,
    policy: {
        policy_id: sameRuntimePolicy.policy_id,
        policy_version: sameRuntimePolicy.policy_version,
    },
    requested_cases: config.cases,
    comparability_formula:
        'source_comparable && checksum_comparable && metric_comparable && provenance_comparable',
    checksum_requirements: Object.fromEntries(
        config.cases.map((name) => [
            name,
            checksumRequirementForCase(name),
        ]),
    ),
    case_sources: Object.fromEntries(
        config.cases.map((name) => [name, caseSourcePath(name)]),
    ),
    environment,
    status_counts: {
        ok: cases.filter((item) => item.status === 'ok').length,
        mismatch: cases.filter((item) => item.status === 'mismatch').length,
        invalid: cases.filter((item) => item.status === 'invalid').length,
    },
    aggregate,
    cases,
};

fs.mkdirSync(path.dirname(config.output), { recursive: true });
fs.writeFileSync(config.output, `${JSON.stringify(summary, null, 2)}\n`);
console.error(`wrote ${config.output}`);

const failureReasons = [];
for (const item of cases) {
    if (item.status !== 'ok') {
        failureReasons.push(
            `case ${item.name} has status ${item.status}: ${item.reason}`,
        );
    }
}
if (!aggregate.complete) {
    failureReasons.push(
        `P0 aggregate incomplete; missing: ${aggregate.missing_cases.join(', ')}`,
    );
}
if (environment.global_surface.status !== 'ok') {
    failureReasons.push(
        `global-surface probe ${environment.global_surface.status}: ${environment.global_surface.reason}`,
    );
}
if (failureReasons.length > 0) {
    console.error('error: same-runtime run failed after writing the artifact:');
    for (const reason of failureReasons) console.error(`  - ${reason}`);
    process.exitCode = 1;
}
