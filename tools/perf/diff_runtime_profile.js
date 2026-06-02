#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const process = require('node:process');

const defaultRegressionRatio = 1.10;
const defaultAbsoluteNs = 1000000;

let outputPath = null;
let emitJson = false;
let failOnRegression = true;
let regressionRatio = defaultRegressionRatio;
let absoluteNs = defaultAbsoluteNs;
let requireMetric = null;

const metricSpecs = {
    total_ns: ['profile', 'total_ns'],
    eval_ns: ['profile', 'eval_ns'],
    vm_run_ns: ['profile', 'vm_run_ns'],
    parse_ns: ['profile', 'parse_ns'],
    opcodes_executed: ['profile', 'opcode_profile', 'opcodes_executed'],
    measured_opcode_ns: ['profile', 'opcode_profile', 'measured_ns'],
    value_dups: ['profile', 'opcode_profile', 'value_dups'],
    value_frees: ['profile', 'opcode_profile', 'value_frees'],
    prop_lookups: ['profile', 'opcode_profile', 'prop_lookups'],
    global_lookups: ['profile', 'opcode_profile', 'global_lookups'],
    opcode_allocations: ['profile', 'opcode_profile', 'allocations'],
    call_frames: ['profile', 'opcode_profile', 'call_frames'],
    alloc_calls: ['profile', 'memory', 'alloc_calls'],
    free_calls: ['profile', 'memory', 'free_calls'],
    create_calls: ['profile', 'memory', 'create_calls'],
    destroy_calls: ['profile', 'memory', 'destroy_calls'],
    allocated_bytes_peak: ['profile', 'memory', 'allocated_bytes_peak'],
    allocation_count_peak: ['profile', 'memory', 'allocation_count_peak'],
};

const opcodeMetricPrefixes = {
    'opcode_count:': 'count',
    'opcode_ns:': 'nanos',
    'opcode_slow:': 'slow',
};

function metricSpecFor(name) {
    if (Object.hasOwn(metricSpecs, name)) return { path: metricSpecs[name] };
    for (const [prefix, field] of Object.entries(opcodeMetricPrefixes)) {
        if (name.startsWith(prefix) && name.length > prefix.length) {
            return { opcodeName: name.slice(prefix.length), opcodeField: field };
        }
    }
    return null;
}

function isKnownMetric(name) {
    return metricSpecFor(name) != null;
}

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'diff_runtime_profile.js')} [options] OLD_PROFILE NEW_PROFILE

Compares two zjs-runtime-profile artifacts produced by run_runtime_profile.js.

Options:
  --output PATH                Write report to PATH instead of stdout
  --json                       Print machine-readable JSON
  --regression-ratio N         Metric regression ratio (default: ${defaultRegressionRatio})
  --absolute-ns N              Minimum timing delta before timing regression fails (default: ${defaultAbsoluteNs})
  --require-improvement METRIC:RATIO
                              Require one metric to be <= old * RATIO
  --warn-regressions           Report regressions but do not fail
  -h, --help                   Show this help

Metrics: ${Object.keys(metricSpecs).join(', ')}
Opcode metrics: opcode_count:NAME, opcode_ns:NAME, opcode_slow:NAME`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function parsePositiveNumber(value, label) {
    if (value == null) fail(`error: ${label} requires a value`);
    const parsed = Number(value);
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`error: ${label} must be a positive number`);
    return parsed;
}

function parseMetricRatio(value, label) {
    if (value == null) fail(`error: ${label} requires METRIC:RATIO`);
    const separator = value.lastIndexOf(':');
    if (separator <= 0 || separator === value.length - 1) fail(`error: ${label} requires METRIC:RATIO`);
    const metric = value.slice(0, separator);
    if (!isKnownMetric(metric)) fail(`error: unknown metric for ${label}: ${metric}`);
    return { metric, ratio: parsePositiveNumber(value.slice(separator + 1), `${label} ratio`) };
}

function readArtifact(filePath, label) {
    let parsed;
    try {
        parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (err) {
        fail(`error: unable to read ${label} profile ${filePath}: ${err.message}`);
    }
    if (!parsed || parsed.tool !== 'zjs-runtime-profile' || !parsed.profile) {
        fail(`error: ${label} profile ${filePath} is not a zjs-runtime-profile artifact`);
    }
    return parsed;
}

function metricValue(artifact, name) {
    const spec = metricSpecFor(name);
    if (spec == null) return null;
    if (spec.opcodeName != null) {
        const rows = artifact.profile?.opcode_profile?.opcodes;
        if (!Array.isArray(rows)) return null;
        const row = rows.find((entry) => entry && entry.name === spec.opcodeName);
        const value = row == null ? 0 : row[spec.opcodeField];
        return Number.isFinite(value) ? value : null;
    }

    let value = artifact;
    for (const key of spec.path) {
        if (value == null || !Object.hasOwn(value, key)) return null;
        value = value[key];
    }
    return Number.isFinite(value) ? value : null;
}

function percentDelta(oldValue, newValue) {
    if (!Number.isFinite(oldValue) || oldValue === 0 || !Number.isFinite(newValue)) return null;
    return ((newValue - oldValue) / oldValue) * 100;
}

function fmtNumber(value) {
    return Number.isFinite(value) ? String(Math.round(value)) : '-';
}

function fmtPercent(value) {
    return value == null || !Number.isFinite(value) ? '-' : `${value >= 0 ? '+' : ''}${value.toFixed(1)}%`;
}

function metricKind(name) {
    if (name.startsWith('opcode_ns:')) return 'time';
    return name.endsWith('_ns') ? 'time' : 'count';
}

function compare(oldArtifact, newArtifact) {
    const failures = [];
    const warnings = [];
    const rows = [];
    const regressions = [];

    if (oldArtifact.script !== newArtifact.script) {
        warnings.push(`script changed: ${oldArtifact.script || '-'} -> ${newArtifact.script || '-'}`);
    }

    const metricNames = Object.keys(metricSpecs);
    if (requireMetric && !metricNames.includes(requireMetric.metric)) metricNames.push(requireMetric.metric);
    for (const name of metricNames) {
        const oldValue = metricValue(oldArtifact, name);
        const newValue = metricValue(newArtifact, name);
        const delta = oldValue == null || newValue == null ? null : newValue - oldValue;
        const deltaPercent = oldValue == null || newValue == null ? null : percentDelta(oldValue, newValue);
        const row = { metric: name, kind: metricKind(name), oldValue, newValue, delta, deltaPercent };
        rows.push(row);

        if (oldValue == null || newValue == null) {
            warnings.push(`metric ${name} is missing from one profile`);
            continue;
        }
        const absoluteBudget = row.kind === 'time' ? absoluteNs : 0;
        if (newValue > oldValue * regressionRatio && newValue - oldValue > absoluteBudget) regressions.push(row);
    }

    if (requireMetric) {
        const oldValue = metricValue(oldArtifact, requireMetric.metric);
        const newValue = metricValue(newArtifact, requireMetric.metric);
        if (oldValue == null || newValue == null) {
            failures.push(`required metric ${requireMetric.metric} is missing`);
        } else if (newValue > oldValue * requireMetric.ratio) {
            failures.push(`metric ${requireMetric.metric} did not meet improvement gate ${requireMetric.ratio}: ${oldValue} -> ${newValue}`);
        }
    }

    if (failOnRegression && regressions.length !== 0) {
        failures.push(`${regressions.length} metric regression(s) exceeded threshold`);
    }

    return {
        ok: failures.length === 0,
        thresholds: { regressionRatio, absoluteNs, failOnRegression, requireMetric },
        summary: {
            oldTimestamp: oldArtifact.timestamp || null,
            newTimestamp: newArtifact.timestamp || null,
            oldZjs: oldArtifact.zjs || null,
            newZjs: newArtifact.zjs || null,
            oldScript: oldArtifact.script || null,
            newScript: newArtifact.script || null,
        },
        failures,
        warnings,
        regressions,
        metrics: rows,
    };
}

function formatText(result) {
    const lines = [
        'summary:',
        `  old timestamp: ${result.summary.oldTimestamp || '-'}`,
        `  new timestamp: ${result.summary.newTimestamp || '-'}`,
        `  script:        ${result.summary.oldScript || '-'} -> ${result.summary.newScript || '-'}`,
        `  zjs:           ${result.summary.oldZjs || '-'} -> ${result.summary.newZjs || '-'}`,
        '',
    ];
    if (result.failures.length !== 0) {
        lines.push('failures:');
        for (const failure of result.failures) lines.push(`  - ${failure}`);
        lines.push('');
    }
    if (result.warnings.length !== 0) {
        lines.push('warnings:');
        for (const warning of result.warnings) lines.push(`  - ${warning}`);
        lines.push('');
    }
    lines.push('metrics:');
    lines.push('  metric                   old          new        delta     delta%');
    for (const row of result.metrics) {
        lines.push(
            `  ${row.metric.padEnd(24)} ${fmtNumber(row.oldValue).padStart(10)} ${fmtNumber(row.newValue).padStart(12)} ${fmtNumber(row.delta).padStart(12)} ${fmtPercent(row.deltaPercent).padStart(9)}`,
        );
    }
    lines.push('');
    return `${lines.join('\n')}`;
}

const positional = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--output':
            outputPath = args[++i] || fail('error: --output requires a path');
            break;
        case '--json':
            emitJson = true;
            break;
        case '--regression-ratio':
            regressionRatio = parsePositiveNumber(args[++i], arg);
            break;
        case '--absolute-ns':
            absoluteNs = parsePositiveNumber(args[++i], arg);
            break;
        case '--require-improvement':
            requireMetric = parseMetricRatio(args[++i], arg);
            break;
        case '--warn-regressions':
            failOnRegression = false;
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default:
            if (arg.startsWith('-')) fail(`error: unknown option: ${arg}`);
            positional.push(arg);
    }
}

if (positional.length !== 2) {
    usage();
    process.exit(2);
}

const oldArtifact = readArtifact(positional[0], 'old');
const newArtifact = readArtifact(positional[1], 'new');
const result = compare(oldArtifact, newArtifact);
const output = emitJson ? `${JSON.stringify(result, null, 2)}\n` : formatText(result);
if (outputPath) {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, output);
} else {
    process.stdout.write(output);
}
process.exit(result.ok ? 0 : 1);
