#!/usr/bin/env bun

import fs from 'node:fs';
import crypto from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { performance } from 'node:perf_hooks';
import { cases as microbenchCases, categories as microbenchCategories } from './microbench_cases.js';
import { cases as hotpathCases, categories as hotpathCategories } from './hotpath_cases.js';
import {
    CONTRACT_EXIT_CODES,
    aggregateVerdict,
    loadPolicy,
    policyReference,
    validateSampleContract,
    validateWarmupContract,
} from './measurement_contract.js';

const toolDir = import.meta.dir;
const root = path.resolve(toolDir, '../..');
const policy = loadPolicy();

const defaultZjs = path.join(root, 'zig-out', 'bin', 'zjs');
const defaultQjs = fs.existsSync(path.join(root, 'build', 'qjs'))
    ? path.join(root, 'build', 'qjs')
    : path.join(root, 'quickjs', 'build', 'qjs');

let zjsBin = process.env.QJS_ZIG || defaultZjs;
let qjsBin = process.env.QJS || defaultQjs;
let iters = parseInteger(process.env.BENCH_ITERS, 10);
let warmup = parseInteger(process.env.BENCH_WARMUP, 3);
let formalMode = false;
let diagnosticMode = false;
let includeUnsupported = false;
let zjsOnly = false;
let emitJson = false;
let outputPath = null;
let emitScriptsDir = null;
let suiteName = 'microbench';
let shouldList = false;
let requestedCpu = null;
let currentAffinity = null;
let collectPmu = false;
let pmuRuns = 4;
let teardownMatched = false;
const selectedCases = [];
const selectedCategories = [];
const peakRssRuns = 2;
const pmuEvents = [
    'instructions',
    'cycles',
    'branches',
    'branch-misses',
    'cache-references',
    'cache-misses',
];
const validationOutputLimit = 4096;

const suites = {
    microbench: {
        cases: microbenchCases,
        categories: microbenchCategories,
        description: 'default compatibility and performance microbench suite',
    },
    hotpath: {
        cases: hotpathCases,
        categories: hotpathCategories,
        description: 'focused hotpath calibration suite',
    },
};

function parseInteger(value, fallback) {
    if (value == null || value === '') return fallback;
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : fallback;
}

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'run_microbench.js')} [options]

Runs zjs-compatible QuickJS microbench-derived cases through both C qjs and zjs.
Each case is checked for matching stdout, stderr, and exit code before timing.
Use --zjs-only for self-baseline reports that compare zjs to a checked-in zjs report.

Options:
  --iters N                 Timed iterations per case and binary (default: ${iters})
  --warmup N                Warmup runs per case and binary (default: ${warmup})
  --formal                  Formal sampling: fail closed on an unbalanced sampling design
  --diagnostic              Explicitly diagnostic run: contract violations are recorded,
                            complete=false and every headline is nulled
  --case NAME               Run one case; repeatable
  --category NAME           Run one category; repeatable
  --suite NAME              Case suite: microbench or hotpath (default: ${suiteName})
  --include-unsupported     Show unsupported cases in the terminal table
  --zjs-only                Use zjs for the reference column; does not require C qjs
  --json                    Print the JSON report to stdout instead of the table
  --output PATH             Write the JSON report to PATH
  --emit-scripts DIR        Write generated benchmark scripts to DIR for profiling
  --cpu N                   Assert that the runner inherited affinity to CPU N;
                            warns and records a mismatch, but never wraps timed children
  --pmu                     Collect the PRD 3.2 instructions-first arbitration metrics;
                            opt in explicitly and pin the outer runner with taskset
  --pmu-runs K              Repetitions per perf stat collection (default: ${pmuRuns})
  --teardown-matched        Run zjs with --leak-check so qjs/zjs both include teardown
  --list                    List available cases and categories, then exit
  --zjs PATH                Path to zjs (default: ${zjsBin})
  --qjs PATH                Path to C qjs (default: ${qjsBin})
  -h, --help                Show this help

Environment:
  QJS_ZIG                   Path to zjs
  QJS                       Path to C qjs
  BENCH_ITERS               Default iteration count
  BENCH_WARMUP              Default warmup count
  ZJS_BUILD_MODE            Explicit build-mode metadata when the binary does not export it
  ZJS_JSVALUE_REPRESENTATION
                            Explicit JSValue representation metadata`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function ensureExecutable(filePath, label, hint) {
    if (!fs.existsSync(filePath)) fail(`error: ${label} not found at ${filePath}\n       ${hint}`);
    try {
        fs.accessSync(filePath, fs.constants.X_OK);
    } catch {
        fail(`error: ${label} is not executable at ${filePath}`);
    }
}

function decodeOutput(value) {
    if (value == null) return '';
    if (typeof value === 'string') return value;
    return new TextDecoder().decode(value);
}

function runCommand(cmd, captureOutput, cwd = undefined) {
    try {
        const proc = Bun.spawnSync({
            cmd,
            cwd,
            stdout: captureOutput ? 'pipe' : 'ignore',
            stderr: captureOutput ? 'pipe' : 'ignore',
        });
        return {
            stdout: captureOutput ? decodeOutput(proc.stdout) : '',
            stderr: captureOutput ? decodeOutput(proc.stderr) : '',
            exitCode: proc.exitCode ?? 1,
            spawnError: null,
        };
    } catch (err) {
        return {
            stdout: '',
            stderr: '',
            exitCode: null,
            spawnError: err instanceof Error ? err.message : String(err),
        };
    }
}

function parseCpuList(mask) {
    const cpus = [];
    for (const segment of mask.split(',')) {
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
    return [...new Set(cpus)];
}

function readCurrentAffinity() {
    try {
        const status = fs.readFileSync('/proc/self/status', 'utf8');
        const mask = status.match(/^Cpus_allowed_list:\s*(.+?)\s*$/m)?.[1] ?? null;
        const cpus = mask == null ? null : parseCpuList(mask);
        if (mask == null || cpus == null || cpus.length === 0) {
            return {
                mask,
                cpus: cpus ?? [],
                pinnedCpu: null,
                affinitySource: 'unpinned',
                unavailableReason: 'unable to parse Cpus_allowed_list from /proc/self/status',
            };
        }
        return {
            mask,
            cpus,
            pinnedCpu: cpus.length === 1 ? cpus[0] : null,
            affinitySource: cpus.length === 1 ? 'inherited' : 'unpinned',
            unavailableReason: null,
        };
    } catch (err) {
        return {
            mask: null,
            cpus: [],
            pinnedCpu: null,
            affinitySource: 'unpinned',
            unavailableReason: err instanceof Error ? err.message : String(err),
        };
    }
}

function initializeAffinity() {
    currentAffinity = readCurrentAffinity();
    const requestedCpuMatches =
        requestedCpu == null ? null : currentAffinity.cpus.length === 1 && currentAffinity.cpus[0] === requestedCpu;
    currentAffinity.requestedCpu = requestedCpu;
    currentAffinity.requestedCpuMatches = requestedCpuMatches;
    if (requestedCpu != null && !requestedCpuMatches) {
        const measured = currentAffinity.mask ?? 'unavailable';
        const warning =
            `--cpu ${requestedCpu} does not match runner Cpus_allowed_list=${measured}; ` +
            'timed children will inherit the measured runner affinity';
        currentAffinity.warning = warning;
        console.error(`warning: ${warning}`);
    }
}

function engineExtraFlags(engine) {
    if (!teardownMatched) return [];
    if (engine === 'zjs' || zjsOnly) return ['--leak-check'];
    return [];
}

function engineCommand(engine, binary, script) {
    return [binary, ...engineExtraFlags(engine), script];
}

function runBinary(engine, binary, script, captureOutput) {
    const result = runCommand(engineCommand(engine, binary, script), captureOutput);
    return {
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode ?? 1,
        spawnError: result.spawnError,
    };
}

function pairOrder(index) {
    return index % 2 === 0 ? ['qjs', 'zjs'] : ['zjs', 'qjs'];
}

function orderAudit(rounds) {
    const sampleOrders = [];
    const firstPositionCounts = { qjs: 0, zjs: 0 };
    for (let index = 0; index < rounds; index += 1) {
        const order = pairOrder(index);
        sampleOrders.push(order.join('->'));
        firstPositionCounts[order[0]] += 1;
    }
    return {
        sampleOrders,
        firstPositionCounts,
        orderBalanced: firstPositionCounts.qjs === firstPositionCounts.zjs,
    };
}

function benchPair(qjsBinary, zjsBinary, script) {
    const binaries = { qjs: qjsBinary, zjs: zjsBinary };
    const qjsSamples = [];
    const zjsSamples = [];
    const pairs = [];
    const warmupOrders = [];
    // `executedOrders` is written as each engine actually completes, so the
    // contract validator compares the artifact's declared order against a
    // record of the run rather than against the same generator that produced it.
    const executedOrders = [];

    for (let i = 0; i < warmup; i += 1) {
        const order = pairOrder(i);
        warmupOrders.push(order.join('->'));
        for (const engine of order) {
            const result = runBinary(engine, binaries[engine], script, false);
            if (result.exitCode !== 0) {
                return {
                    status: 'failed',
                    failure: {
                        phase: 'warmup',
                        index: i,
                        engine,
                        exitCode: result.exitCode,
                        spawnError: result.spawnError,
                    },
                    qjsSamples,
                    zjsSamples,
                    pairs,
                    warmupOrders,
                    executedOrders,
                };
            }
        }
    }

    for (let i = 0; i < iters; i += 1) {
        const order = pairOrder(i);
        const executed = [];
        executedOrders.push(executed);
        const elapsed = {};
        for (const engine of order) {
            const start = performance.now();
            const result = runBinary(engine, binaries[engine], script, false);
            elapsed[engine] = performance.now() - start;
            if (result.exitCode !== 0) {
                return {
                    status: 'failed',
                    failure: {
                        phase: 'timed',
                        index: i,
                        engine,
                        exitCode: result.exitCode,
                        spawnError: result.spawnError,
                    },
                    qjsSamples,
                    zjsSamples,
                    pairs,
                    warmupOrders,
                    executedOrders,
                };
            }
            executed.push(engine);
        }
        qjsSamples.push(elapsed.qjs);
        zjsSamples.push(elapsed.zjs);
        pairs.push({
            index: i,
            order: order.join('->'),
            executedOrder: executed.join('->'),
            qjsMs: elapsed.qjs,
            zjsMs: elapsed.zjs,
        });
    }
    return {
        status: 'ok',
        failure: null,
        qjsSamples,
        zjsSamples,
        pairs,
        warmupOrders,
        executedOrders,
    };
}

function quantile(samples, fraction) {
    if (samples.length === 0) return null;
    const sorted = [...samples].sort((a, b) => a - b);
    const index = (sorted.length - 1) * fraction;
    const lower = Math.floor(index);
    const upper = Math.ceil(index);
    if (lower === upper) return sorted[lower];
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}

function stats(samples) {
    if (samples.length === 0) return null;
    const sorted = [...samples].sort((a, b) => a - b);
    const avg = sorted.reduce((sum, value) => sum + value, 0) / sorted.length;
    const median = quantile(sorted, 0.5);
    const variance = sorted.reduce((sum, value) => sum + (value - avg) ** 2, 0) / sorted.length;
    return {
        samples,
        avg,
        median,
        p25: quantile(sorted, 0.25),
        p75: quantile(sorted, 0.75),
        min: sorted[0],
        max: sorted[sorted.length - 1],
        stdev: Math.sqrt(variance),
    };
}

function geometricMean(values) {
    const sum = values.reduce((acc, value) => acc + Math.log(value), 0);
    return Math.exp(sum / values.length);
}

function pairedStats(pairs) {
    const ratios = pairs.map((pair) => pair.zjsMs / pair.qjsMs);
    return {
        ratios,
        median: quantile(ratios, 0.5),
        p25: quantile(ratios, 0.25),
        p75: quantile(ratios, 0.75),
        geomean: ratios.length === 0 ? null : geometricMean(ratios),
    };
}

function firstDifferenceLine(expected, actual) {
    const expectedLines = expected.split('\n');
    const actualLines = actual.split('\n');
    const limit = Math.max(expectedLines.length, actualLines.length);
    for (let i = 0; i < limit; i += 1) {
        if ((expectedLines[i] ?? '') !== (actualLines[i] ?? '')) return i + 1;
    }
    return 0;
}

function summarizeMismatch(expected, actual) {
    if (expected.exitCode !== actual.exitCode) return `rc ${expected.exitCode} vs ${actual.exitCode}`;
    if (expected.stdout !== actual.stdout) return `stdout mismatch at line ${firstDifferenceLine(expected.stdout, actual.stdout)}`;
    if (expected.stderr !== actual.stderr) return `stderr mismatch at line ${firstDifferenceLine(expected.stderr, actual.stderr)}`;
    return 'unknown mismatch';
}

function truncateText(text, limit = validationOutputLimit) {
    if (text.length <= limit) return text;
    return `${text.slice(0, limit)}\n...[truncated ${text.length - limit} bytes]`;
}

function validationCheckSnapshot(result) {
    return {
        exitCode: result.exitCode,
        stdout: truncateText(result.stdout),
        stderr: truncateText(result.stderr),
        ...(result.spawnError ? { spawnError: result.spawnError } : {}),
    };
}

function validationResult(expected, actual) {
    const stdoutMatch = expected.stdout === actual.stdout;
    const stderrMatch = expected.stderr === actual.stderr;
    const exitCodeMatch = expected.exitCode === actual.exitCode;
    const validation = {
        stdoutMatch,
        stderrMatch,
        exitCodeMatch,
        exitCode: exitCodeMatch ? expected.exitCode : null,
    };
    if (!stdoutMatch || !stderrMatch || !exitCodeMatch) {
        validation.qjs = validationCheckSnapshot(expected);
        validation.zjs = validationCheckSnapshot(actual);
    }
    return validation;
}

function validationPassed(validation) {
    return validation.stdoutMatch && validation.stderrMatch && validation.exitCodeMatch;
}

function emptyPmuValues() {
    return Object.fromEntries(pmuEvents.map((event) => [event, null]));
}

const pmuAggregation =
    'arithmetic mean across individually collected process invocations; each invocation selects exactly one countable PMU row per event, and multiple countable PMUs invalidate that event';

function unavailablePmu(reason, status = 'unavailable') {
    return {
        status,
        runs: pmuRuns,
        events: pmuEvents,
        aggregation: pmuAggregation,
        sampleOrders: [],
        orderBalanced: null,
        qjs: emptyPmuValues(),
        zjs: emptyPmuValues(),
        qjsSamples: [],
        zjsSamples: [],
        arbitrationMetricUnavailable: true,
        unavailableReason: reason,
    };
}

function unavailablePeakRss(reason) {
    return {
        status: 'unavailable',
        runs: peakRssRuns,
        qjs: null,
        zjs: null,
        qjsSamples: [],
        zjsSamples: [],
        sampleOrders: [],
        orderBalanced: null,
        unit: 'KiB',
        aggregation: 'median across individually collected process invocations',
        qjsUnavailableReason: reason,
        zjsUnavailableReason: reason,
    };
}

function unavailableAllocationMetric(metric) {
    return {
        qjs: null,
        zjs: null,
        unavailableReason: `${metric} is not exposed by the whole-process runner`,
    };
}

function unavailableCaseMeasurements(reason) {
    return {
        pmu: unavailablePmu(reason),
        peakRssKb: unavailablePeakRss(reason),
        allocations: unavailableAllocationMetric('allocation count'),
        allocatedBytes: unavailableAllocationMetric('allocated bytes'),
    };
}

function perfEventKey(rawEvent) {
    const normalized = rawEvent.trim().toLowerCase();
    const aliases = {
        'branch-instructions': 'branches',
        'branch-misses': 'branch-misses',
        instructions: 'instructions',
        cycles: 'cycles',
        branches: 'branches',
        'cache-references': 'cache-references',
        'cache-misses': 'cache-misses',
    };
    for (const [suffix, event] of Object.entries(aliases)) {
        if (
            normalized === suffix ||
            normalized.endsWith(`/${suffix}/`) ||
            normalized.endsWith(`/${suffix}`)
        ) {
            return event;
        }
    }
    return null;
}

function perfPmuName(rawEvent) {
    const normalized = rawEvent.trim();
    const slash = normalized.indexOf('/');
    return slash > 0 ? normalized.slice(0, slash) : 'generic';
}

function parsePerfCsv(stderr) {
    const rowsByEvent = Object.fromEntries(pmuEvents.map((event) => [event, []]));
    for (const line of stderr.split('\n')) {
        const fields = line.split(',');
        if (fields.length < 3) continue;
        const rawEvent = fields[2].trim();
        const event = perfEventKey(rawEvent);
        if (!event) continue;
        const rawCount = fields[0].trim();
        const row = {
            event,
            pmu: perfPmuName(rawEvent),
            rawEvent,
            rawCount,
            rawLine: line,
            disposition: null,
        };
        if (rawCount.length === 0) {
            row.disposition = 'discarded-empty-count';
            rowsByEvent[event].push(row);
            continue;
        }
        if (rawCount.includes('<not counted>')) {
            row.disposition = 'discarded-not-counted';
            rowsByEvent[event].push(row);
            continue;
        }
        if (rawCount.includes('<not supported>')) {
            row.disposition = 'discarded-not-supported';
            rowsByEvent[event].push(row);
            continue;
        }
        const count = Number(rawCount.replace(/\s+/g, ''));
        if (!Number.isFinite(count)) {
            row.disposition = 'discarded-non-numeric';
            rowsByEvent[event].push(row);
            continue;
        }
        row.count = count;
        row.disposition = 'countable';
        rowsByEvent[event].push(row);
    }

    const values = {};
    const missing = [];
    const ambiguous = [];
    const eventAudit = {};
    for (const event of pmuEvents) {
        const rows = rowsByEvent[event];
        const countable = rows.filter((row) => row.disposition === 'countable');
        const countablePmus = [...new Set(countable.map((row) => row.pmu))];
        if (countable.length === 0) {
            values[event] = null;
            missing.push(event);
            eventAudit[event] = {
                status: 'missing',
                selectedPmu: null,
                countablePmus,
                discardedRows: rows,
            };
            continue;
        }
        if (countablePmus.length !== 1 || countable.length !== 1) {
            for (const row of countable) row.disposition = 'rejected-ambiguous-countable';
            values[event] = null;
            ambiguous.push(event);
            eventAudit[event] = {
                status: 'ambiguous',
                selectedPmu: null,
                countablePmus,
                countableRows: countable,
                discardedRows: rows.filter((row) => row.disposition !== 'countable'),
                reason:
                    `expected exactly one countable PMU row, got ${countable.length} ` +
                    `across ${countablePmus.length} PMU(s)`,
            };
            continue;
        }
        const selected = countable[0];
        selected.disposition = 'selected';
        values[event] = selected.count;
        eventAudit[event] = {
            status: 'selected',
            selectedPmu: selected.pmu,
            value: selected.count,
            countablePmus,
            selectedRow: selected,
            discardedRows: rows.filter((row) => row !== selected),
        };
    }
    return {
        values,
        missing,
        ambiguous,
        eventAudit,
        rawRows: pmuEvents.flatMap((event) => rowsByEvent[event]),
    };
}

function collectEnginePmu(engine, binary, script) {
    const command = [
        'perf',
        'stat',
        '-r',
        '1',
        '-x,',
        '-e',
        pmuEvents.join(','),
        '--',
        ...engineCommand(engine, binary, script),
    ];
    const result = runCommand(command, true);
    if (result.spawnError || result.exitCode !== 0) {
        const detail = result.spawnError || truncateText(result.stderr.trim(), 8192) || 'no stderr';
        return {
            status: 'unavailable',
            values: emptyPmuValues(),
            eventAudit: {},
            rawRows: [],
            command,
            unavailableReason: `perf stat failed (exit ${result.exitCode ?? 'unavailable'}): ${detail}`,
        };
    }

    const parsed = parsePerfCsv(result.stderr);
    if (parsed.ambiguous.length !== 0) {
        return {
            status: 'invalid',
            values: parsed.values,
            eventAudit: parsed.eventAudit,
            rawRows: parsed.rawRows,
            command,
            unavailableReason:
                `multiple countable PMU rows made these events ambiguous: ${parsed.ambiguous.join(', ')}`,
        };
    }
    if (parsed.missing.length === pmuEvents.length) {
        return {
            status: 'unavailable',
            values: emptyPmuValues(),
            eventAudit: parsed.eventAudit,
            rawRows: parsed.rawRows,
            command,
            unavailableReason: `perf stat returned no countable requested events: ${truncateText(result.stderr.trim(), 8192)}`,
        };
    }
    if (parsed.missing.length !== 0) {
        return {
            status: 'partial',
            values: parsed.values,
            eventAudit: parsed.eventAudit,
            rawRows: parsed.rawRows,
            command,
            unavailableReason: `missing events after discarding uncounted/unsupported PMUs: ${parsed.missing.join(', ')}`,
        };
    }
    return {
        status: 'ok',
        values: parsed.values,
        eventAudit: parsed.eventAudit,
        rawRows: parsed.rawRows,
        command,
        unavailableReason: null,
    };
}

function arithmeticMean(values) {
    return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function aggregateEnginePmu(samples) {
    const values = {};
    const eventAudit = {};
    const reasons = [];
    for (const event of pmuEvents) {
        const ambiguousSamples = [];
        const missingSamples = [];
        const selected = [];
        for (const sample of samples) {
            const audit = sample.eventAudit[event];
            if (audit?.status === 'ambiguous') {
                ambiguousSamples.push(sample.round);
                continue;
            }
            const value = sample.values[event];
            if (!Number.isFinite(value)) {
                missingSamples.push(sample.round);
                continue;
            }
            selected.push({
                round: sample.round,
                value,
                pmu: audit?.selectedPmu ?? null,
            });
        }
        const selectedPmus = [...new Set(selected.map((sample) => sample.pmu).filter(Boolean))];
        let status = 'ok';
        if (ambiguousSamples.length !== 0) {
            status = 'invalid';
            values[event] = null;
            reasons.push(`${event}: ambiguous PMU rows in round(s) ${ambiguousSamples.join(', ')}`);
        } else if (selected.length === 0) {
            status = 'unavailable';
            values[event] = null;
            reasons.push(`${event}: no countable samples`);
        } else {
            values[event] = arithmeticMean(selected.map((sample) => sample.value));
            if (selected.length !== pmuRuns) {
                status = 'partial';
                reasons.push(`${event}: ${selected.length}/${pmuRuns} countable samples`);
            }
        }
        eventAudit[event] = {
            status,
            aggregation: 'arithmetic mean of selected per-invocation counts',
            samplesExpected: pmuRuns,
            samplesUsed: selected.length,
            selectedPmus,
            selectedSamples: selected,
            missingSamples,
            ambiguousSamples,
        };
    }
    const statuses = Object.values(eventAudit).map((audit) => audit.status);
    const status = statuses.includes('invalid')
        ? 'invalid'
        : statuses.every((value) => value === 'ok')
          ? 'ok'
          : statuses.every((value) => value === 'unavailable')
            ? 'unavailable'
            : 'partial';
    return {
        status,
        values,
        eventAudit,
        unavailableReason: reasons.length === 0 ? null : reasons.join('; '),
    };
}

function collectCasePmu(qjsBinary, zjsBinary, script) {
    if (!collectPmu) return unavailablePmu('PMU collection disabled; pass --pmu', 'disabled');
    const binaries = { qjs: qjsBinary, zjs: zjsBinary };
    const samples = { qjs: [], zjs: [] };
    const sampleOrders = [];
    for (let round = 0; round < pmuRuns; round += 1) {
        const order = pairOrder(round);
        sampleOrders.push(order.join('->'));
        for (let position = 0; position < order.length; position += 1) {
            const engine = order[position];
            samples[engine].push({
                round,
                position,
                order: order.join('->'),
                ...collectEnginePmu(engine, binaries[engine], script),
            });
        }
    }
    const qjsResult = aggregateEnginePmu(samples.qjs);
    const zjsResult = aggregateEnginePmu(samples.zjs);
    const statuses = [qjsResult.status, zjsResult.status];
    const status = statuses.includes('invalid')
        ? 'invalid'
        : statuses.every((value) => value === 'ok')
        ? 'ok'
        : statuses.every((value) => value === 'unavailable')
          ? 'unavailable'
          : 'partial';
    const unavailableReason = [
        qjsResult.unavailableReason ? `qjs: ${qjsResult.unavailableReason}` : null,
        zjsResult.unavailableReason ? `zjs: ${zjsResult.unavailableReason}` : null,
    ].filter(Boolean).join('\n');
    return {
        status,
        runs: pmuRuns,
        events: pmuEvents,
        aggregation: pmuAggregation,
        collector:
            'perf stat -r 1 per engine per round; perf and measured children inherit the runner affinity without taskset wrapping',
        sampleOrders,
        firstPositionCounts: orderAudit(pmuRuns).firstPositionCounts,
        orderBalanced: orderAudit(pmuRuns).orderBalanced,
        qjs: qjsResult.values,
        zjs: zjsResult.values,
        qjsSamples: samples.qjs,
        zjsSamples: samples.zjs,
        eventAudit: {
            qjs: qjsResult.eventAudit,
            zjs: zjsResult.eventAudit,
        },
        arbitrationMetricUnavailable:
            !Number.isFinite(qjsResult.values.instructions) || !Number.isFinite(zjsResult.values.instructions),
        ...(unavailableReason ? { unavailableReason } : {}),
        ...(qjsResult.unavailableReason ? { qjsUnavailableReason: qjsResult.unavailableReason } : {}),
        ...(zjsResult.unavailableReason ? { zjsUnavailableReason: zjsResult.unavailableReason } : {}),
    };
}

function collectEnginePeakRss(engine, binary, script) {
    const timeBinary = '/usr/bin/time';
    if (!fs.existsSync(timeBinary)) {
        return { value: null, unavailableReason: `${timeBinary} is not available` };
    }
    const marker = '__ZJS_PEAK_RSS_KB__=';
    const command = [timeBinary, '-f', `${marker}%M`, '--', ...engineCommand(engine, binary, script)];
    const result = runCommand(command, true);
    if (result.spawnError || result.exitCode !== 0) {
        const detail = result.spawnError || truncateText(result.stderr.trim(), 4096) || 'no stderr';
        return {
            value: null,
            command,
            unavailableReason: `peak RSS probe failed (exit ${result.exitCode ?? 'unavailable'}): ${detail}`,
        };
    }
    const matches = [...result.stderr.matchAll(new RegExp(`${marker}(\\d+)`, 'g'))];
    if (matches.length === 0) {
        return {
            value: null,
            command,
            unavailableReason: `peak RSS marker missing from /usr/bin/time stderr: ${truncateText(result.stderr.trim(), 4096)}`,
        };
    }
    return {
        value: Number(matches[matches.length - 1][1]),
        command,
        unavailableReason: null,
    };
}

function collectCasePeakRss(qjsBinary, zjsBinary, script) {
    const binaries = { qjs: qjsBinary, zjs: zjsBinary };
    const samples = { qjs: [], zjs: [] };
    const sampleOrders = [];
    for (let round = 0; round < peakRssRuns; round += 1) {
        const order = pairOrder(round);
        sampleOrders.push(order.join('->'));
        for (let position = 0; position < order.length; position += 1) {
            const engine = order[position];
            samples[engine].push({
                round,
                position,
                order: order.join('->'),
                ...collectEnginePeakRss(engine, binaries[engine], script),
            });
        }
    }
    const qjsValues = samples.qjs.map((sample) => sample.value).filter(Number.isFinite);
    const zjsValues = samples.zjs.map((sample) => sample.value).filter(Number.isFinite);
    const reasons = [];
    for (const engine of ['qjs', 'zjs']) {
        for (const sample of samples[engine]) {
            if (sample.unavailableReason) reasons.push(`${engine} round ${sample.round}: ${sample.unavailableReason}`);
        }
    }
    const qjs = qjsValues.length === 0 ? null : quantile(qjsValues, 0.5);
    const zjs = zjsValues.length === 0 ? null : quantile(zjsValues, 0.5);
    const status = qjsValues.length === peakRssRuns && zjsValues.length === peakRssRuns
        ? 'ok'
        : qjs == null && zjs == null
          ? 'unavailable'
          : 'partial';
    const audit = orderAudit(peakRssRuns);
    return {
        status,
        runs: peakRssRuns,
        qjs,
        zjs,
        qjsSamples: samples.qjs,
        zjsSamples: samples.zjs,
        sampleOrders,
        firstPositionCounts: audit.firstPositionCounts,
        orderBalanced: audit.orderBalanced,
        unit: 'KiB',
        collector: '/usr/bin/time -f %M',
        aggregation: 'median across individually collected process invocations',
        affinity:
            '/usr/bin/time and measured children inherit the runner affinity without taskset wrapping',
        ...(reasons.length !== 0 ? { unavailableReason: reasons.join('\n') } : {}),
    };
}

function firstLine(text) {
    if (!text) return null;
    return text.split(/\r?\n/, 1)[0] || null;
}

function commandProbe(command, args, { allowNonZero = false, cwd = undefined } = {}) {
    const result = runCommand([command, ...args], true, cwd);
    if (result.spawnError) {
        return { value: null, result, unavailableReason: result.spawnError };
    }
    if (!allowNonZero && result.exitCode !== 0) {
        const detail = result.stderr.trim() || result.stdout.trim() || 'no output';
        return {
            value: null,
            result,
            unavailableReason: `${command} exited ${result.exitCode}: ${truncateText(detail, 2048)}`,
        };
    }
    return { value: result.stdout.trim(), result, unavailableReason: null };
}

function sha256File(filePath) {
    try {
        return {
            value: crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex'),
            unavailableReason: null,
        };
    } catch (err) {
        return {
            value: null,
            unavailableReason: err instanceof Error ? err.message : String(err),
        };
    }
}

function realpathOrResolved(filePath) {
    const resolved = path.resolve(process.cwd(), filePath);
    try {
        return fs.realpathSync(resolved);
    } catch {
        return resolved;
    }
}

function gitIdentityForDirectory(directory) {
    const rootProbe = commandProbe('git', ['-C', directory, 'rev-parse', '--show-toplevel']);
    if (!rootProbe.value) {
        const reason =
            rootProbe.unavailableReason || `git could not determine a repository containing ${directory}`;
        return {
            repository: null,
            commit: null,
            dirty: null,
            repositoryUnavailableReason: reason,
            commitUnavailableReason: reason,
            dirtyUnavailableReason: reason,
        };
    }
    const repository = rootProbe.value;
    const commitProbe = commandProbe('git', ['-C', repository, 'rev-parse', 'HEAD']);
    const statusProbe = commandProbe('git', ['-C', repository, 'status', '--porcelain']);
    return {
        repository,
        commit: commitProbe.value || null,
        dirty: statusProbe.unavailableReason ? null : statusProbe.value.length !== 0,
        ...(commitProbe.unavailableReason
            ? { commitUnavailableReason: commitProbe.unavailableReason }
            : {}),
        ...(statusProbe.unavailableReason
            ? { dirtyUnavailableReason: statusProbe.unavailableReason }
            : {}),
    };
}

function gitIdentityForBinary(binary) {
    return gitIdentityForDirectory(path.dirname(realpathOrResolved(binary)));
}

function detectCpuModel() {
    const lscpu = commandProbe('lscpu', [], { allowNonZero: false });
    if (lscpu.value) {
        const models = [...new Set(
            lscpu.value
                .split(/\r?\n/)
                .map((line) => line.match(/^\s*Model name:\s*(.+?)\s*$/)?.[1])
                .filter((value) => value && value.toLowerCase() !== 'unknown' && value !== '-'),
        )];
        if (models.length !== 0) {
            return {
                model: models.join(' / '),
                source: 'lscpu Model name',
                rawProbe: models.map((model) => `Model name: ${model}`).join('\n'),
            };
        }
    }

    let cpuinfo = '';
    try {
        cpuinfo = fs.readFileSync('/proc/cpuinfo', 'utf8');
    } catch {
        cpuinfo = '';
    }
    const identityLines = cpuinfo
        .split(/\r?\n/)
        .filter((line) => /^(model name|Hardware|Processor|CPU implementer|CPU part)\s*:/i.test(line));
    const namedModels = [...new Set(
        identityLines
            .map((line) => line.match(/^(?:model name|Hardware|Processor)\s*:\s*(.+?)\s*$/i)?.[1])
            .filter((value) => value && value.toLowerCase() !== 'unknown' && value !== '-'),
    )];
    if (namedModels.length !== 0) {
        return {
            model: namedModels.join(' / '),
            source: '/proc/cpuinfo model identity',
            rawProbe: [...new Set(identityLines)].join('\n'),
        };
    }

    const implementers = [...new Set(
        identityLines
            .map((line) => line.match(/^CPU implementer\s*:\s*(.+?)\s*$/i)?.[1])
            .filter(Boolean),
    )];
    const parts = [...new Set(
        identityLines
            .map((line) => line.match(/^CPU part\s*:\s*(.+?)\s*$/i)?.[1])
            .filter(Boolean),
    )];
    if (implementers.length !== 0 || parts.length !== 0) {
        const implementerText = implementers.length === 0 ? 'unknown implementer' : `implementer ${implementers.join('/')}`;
        const partText = parts.length === 0 ? 'unknown parts' : `parts ${parts.join('/')}`;
        return {
            model: `ARM ${implementerText}, ${partText}`,
            source: '/proc/cpuinfo implementer/part',
            rawProbe: [...new Set(identityLines)].join('\n'),
        };
    }

    const rawProbe = [
        lscpu.value || lscpu.unavailableReason || '',
        ...identityLines,
    ].filter(Boolean).join('\n');
    return {
        model: 'unknown',
        source: 'lscpu and /proc/cpuinfo',
        rawProbe: truncateText(rawProbe || 'no CPU identity output', 8192),
    };
}

function collectMetadata() {
    const resolvedZjs = realpathOrResolved(zjsBin);
    const resolvedQjs = zjsOnly ? null : realpathOrResolved(qjsBin);
    const zjsIdentity = gitIdentityForBinary(resolvedZjs);
    const toolIdentity = gitIdentityForDirectory(root);
    const zjsHash = sha256File(resolvedZjs);
    const zjsBuildMode = process.env.ZJS_BUILD_MODE?.trim() || null;
    const zjsRepresentation = process.env.ZJS_JSVALUE_REPRESENTATION?.trim() || null;

    let qjsIdentity = null;
    let qjsVersion = null;
    let qjsVersionReason = 'not applicable in --zjs-only mode';
    let qjsHelp = null;
    let qjsVersionCrossCheck = null;
    let qjsCrossCheckReason = 'not applicable in --zjs-only mode';
    let qjsHash = { value: null, unavailableReason: 'not applicable in --zjs-only mode' };
    if (!zjsOnly) {
        qjsIdentity = gitIdentityForBinary(resolvedQjs);
        if (qjsIdentity.repository) {
            try {
                qjsVersion = fs.readFileSync(path.join(qjsIdentity.repository, 'VERSION'), 'utf8').trim();
                qjsVersionReason = null;
            } catch (err) {
                qjsVersionReason = err instanceof Error ? err.message : String(err);
            }
        } else {
            qjsVersionReason =
                qjsIdentity.repositoryUnavailableReason ||
                'QuickJS VERSION unavailable because the binary repository could not be determined';
        }
        const helpProbe = commandProbe(resolvedQjs, ['--help'], { allowNonZero: true });
        qjsHelp = {
            line: firstLine(helpProbe.result.stdout.trim()),
            exitCode: helpProbe.result.exitCode,
            unavailableReason:
                helpProbe.unavailableReason ||
                (firstLine(helpProbe.result.stdout.trim()) == null
                    ? 'qjs --help produced no stdout first line'
                    : null),
        };
        if (qjsVersion && qjsHelp.line) {
            qjsVersionCrossCheck = qjsHelp.line.includes(qjsVersion);
            qjsCrossCheckReason = qjsVersionCrossCheck
                ? null
                : `VERSION=${qjsVersion}, help first line=${qjsHelp.line}`;
        } else {
            qjsCrossCheckReason = 'VERSION file or qjs --help stdout first line unavailable';
        }
        qjsHash = sha256File(resolvedQjs);
    }

    const zig = commandProbe('zig', ['version']);
    const cc = commandProbe('cc', ['--version']);
    const node = commandProbe('node', ['--version']);
    const bunVersion = process.versions.bun || null;
    const kernel = commandProbe('uname', ['-r']);
    const perfVersion = commandProbe('perf', ['--version']);
    const cpuModel = detectCpuModel();
    const timedOrder = orderAudit(iters);
    const warmupOrder = orderAudit(warmup);
    const pmuOrder = orderAudit(pmuRuns);
    const peakRssOrder = orderAudit(peakRssRuns);
    const zjsLifecycle = {
        actualEngine: 'zjs',
        includesTeardown: teardownMatched,
        leakCheck: teardownMatched,
        extraFlags: teardownMatched ? ['--leak-check'] : [],
        reason: teardownMatched
            ? 'zjs --leak-check runs runtime.deinit() before successful process exit'
            : 'src/cli/zjs.zig deliberately skips runtime.deinit() on the happy path',
    };
    const qjsLifecycle = zjsOnly
        ? {
            actualEngine: 'zjs self-reference',
            includesTeardown: teardownMatched,
            leakCheck: teardownMatched,
            extraFlags: teardownMatched ? ['--leak-check'] : [],
            reason: 'the qjs report column is the same zjs binary in --zjs-only mode',
        }
        : {
            actualEngine: 'qjs',
            includesTeardown: true,
            leakCheck: false,
            extraFlags: [],
            reason: 'Bellard qjs unconditionally frees handlers, context, and runtime before exit',
        };
    const lifecycleComparable = zjsOnly || teardownMatched;

    const meta = {
        zjs: {
            commit: zjsIdentity.commit,
            dirty: zjsIdentity.dirty,
            repository: zjsIdentity.repository,
            binary: resolvedZjs,
            sha256: zjsHash.value,
            buildMode: zjsBuildMode,
            jsvalueRepresentation: zjsRepresentation,
            provenance:
                'repository commit and dirty state are inferred from the binary realpath; SHA-256 is the authoritative binary identity',
        },
        qjs: {
            commit: qjsIdentity?.commit ?? null,
            dirty: qjsIdentity?.dirty ?? null,
            version: qjsVersion,
            binary: resolvedQjs,
            sha256: qjsHash.value,
            repository: qjsIdentity?.repository ?? null,
            helpVersionLine: qjsHelp?.line ?? null,
            helpExitCode: qjsHelp?.exitCode ?? null,
            versionCrossCheck: qjsVersionCrossCheck,
            provenance: zjsOnly
                ? null
                : 'repository commit and dirty state are inferred from the binary realpath; SHA-256 is the authoritative binary identity',
        },
        toolRepoCommit: {
            commit: toolIdentity.commit,
            dirty: toolIdentity.dirty,
            repository: toolIdentity.repository,
        },
        toolchain: {
            zig: firstLine(zig.value),
            cc: firstLine(cc.value),
            bun: bunVersion,
            node: firstLine(node.value),
        },
        host: {
            cpuModel: cpuModel.model,
            cpuModelProbeSource: cpuModel.source,
            pinnedCpu: currentAffinity.pinnedCpu,
            requestedCpu,
            affinitySource: currentAffinity.affinitySource,
            affinityMask: currentAffinity.mask,
            affinityCpus: currentAffinity.cpus,
            requestedCpuMatches: currentAffinity.requestedCpuMatches,
            kernel: firstLine(kernel.value) || os.release(),
            arch: os.arch(),
        },
        sampling: {
            warmup,
            iters,
            order: 'ABBA per-sample interleaved',
            orderDescription:
                'Warmup and timed rounds both alternate: zero-based even rounds run qjs then zjs; odd rounds run zjs then qjs. The two engines in each round are adjacent processes.',
            // Order-audit sub-objects. `warmupOrder` must NOT be named `warmup`:
            // that key already carries the PRD 3.1 warmup *count* above, and a
            // duplicate key would silently shadow it.
            timed: timedOrder,
            warmupOrder,
            pmu: pmuOrder,
            peakRss: peakRssOrder,
        },
        lifecycle: {
            layer: 'whole-process',
            includesParser: true,
            includesCompile: true,
            includesContextCreate: true,
            mode: teardownMatched ? 'teardown-matched' : 'normal-cli',
            qjs: qjsLifecycle,
            zjs: zjsLifecycle,
            comparable: lifecycleComparable,
            comparisonReason: lifecycleComparable
                ? zjsOnly
                    ? 'both report columns execute the same zjs lifecycle'
                    : 'qjs normal teardown is compared with zjs --leak-check teardown'
                : 'qjs includes teardown while normal zjs intentionally relies on OS process cleanup',
        },
        validation: {
            occursBeforeTiming: true,
            compares: ['stdout', 'stderr', 'exitCode'],
            mismatchDisposition: 'invalid and excluded from case and summary statistics',
        },
        pmu: {
            enabled: collectPmu,
            runs: pmuRuns,
            events: pmuEvents,
            aggregation: pmuAggregation,
            perfVersion: firstLine(perfVersion.value),
            pinnedCpu: currentAffinity.pinnedCpu,
            affinitySource: currentAffinity.affinitySource,
            affinityMask: currentAffinity.mask,
            affinityPolicy:
                'perf stat and measured children inherit the outer runner affinity; no measured binary is wrapped in taskset',
            arbitrationMetricUnavailable: collectPmu ? null : true,
        },
        peakRssKb: {
            enabled: true,
            runs: peakRssRuns,
            collector: '/usr/bin/time -f %M',
            unit: 'KiB',
            aggregation: 'median across individually collected process invocations',
            affinityPolicy:
                '/usr/bin/time and measured children inherit the outer runner affinity; no measured binary is wrapped in taskset',
        },
        allocations: {
            available: false,
            unavailableReason: 'allocation count is not exposed by the whole-process runner',
        },
        allocatedBytes: {
            available: false,
            unavailableReason: 'allocated bytes are not exposed by the whole-process runner',
        },
    };

    if (zjsIdentity.commitUnavailableReason) {
        meta.zjs.commitUnavailableReason = zjsIdentity.commitUnavailableReason;
    }
    if (zjsIdentity.dirtyUnavailableReason) {
        meta.zjs.dirtyUnavailableReason = zjsIdentity.dirtyUnavailableReason;
    }
    if (zjsIdentity.repositoryUnavailableReason) {
        meta.zjs.repositoryUnavailableReason = zjsIdentity.repositoryUnavailableReason;
    }
    if (zjsHash.unavailableReason) meta.zjs.sha256UnavailableReason = zjsHash.unavailableReason;
    if (!zjsBuildMode) {
        meta.zjs.buildModeUnavailableReason =
            'the binary does not export its Zig optimize mode; set ZJS_BUILD_MODE when invoking the runner';
    }
    if (!zjsRepresentation) {
        meta.zjs.jsvalueRepresentationUnavailableReason =
            'the binary does not export its JSValue representation; set ZJS_JSVALUE_REPRESENTATION when invoking the runner';
    }
    if (zjsOnly) {
        const reason = 'not applicable in --zjs-only mode; the reference column is zjs';
        meta.qjs.commitUnavailableReason = reason;
        meta.qjs.dirtyUnavailableReason = reason;
        meta.qjs.repositoryUnavailableReason = reason;
        meta.qjs.binaryUnavailableReason = reason;
        meta.qjs.sha256UnavailableReason = reason;
    } else {
        if (qjsIdentity?.commitUnavailableReason) {
            meta.qjs.commitUnavailableReason = qjsIdentity.commitUnavailableReason;
        }
        if (qjsIdentity?.dirtyUnavailableReason) {
            meta.qjs.dirtyUnavailableReason = qjsIdentity.dirtyUnavailableReason;
        }
        if (qjsIdentity?.repositoryUnavailableReason) {
            meta.qjs.repositoryUnavailableReason = qjsIdentity.repositoryUnavailableReason;
        }
    }
    if (qjsVersionReason) meta.qjs.versionUnavailableReason = qjsVersionReason;
    if (!zjsOnly && qjsHash.unavailableReason) {
        meta.qjs.sha256UnavailableReason = qjsHash.unavailableReason;
    }
    if (qjsHelp?.unavailableReason) meta.qjs.helpVersionLineUnavailableReason = qjsHelp.unavailableReason;
    if (qjsCrossCheckReason) meta.qjs.versionCrossCheckReason = qjsCrossCheckReason;
    if (toolIdentity.commitUnavailableReason) {
        meta.toolRepoCommit.commitUnavailableReason = toolIdentity.commitUnavailableReason;
    }
    if (toolIdentity.dirtyUnavailableReason) {
        meta.toolRepoCommit.dirtyUnavailableReason = toolIdentity.dirtyUnavailableReason;
    }
    if (toolIdentity.repositoryUnavailableReason) {
        meta.toolRepoCommit.repositoryUnavailableReason = toolIdentity.repositoryUnavailableReason;
    }
    if (zig.unavailableReason) meta.toolchain.zigUnavailableReason = zig.unavailableReason;
    if (cc.unavailableReason) meta.toolchain.ccUnavailableReason = cc.unavailableReason;
    if (!bunVersion) meta.toolchain.bunUnavailableReason = 'process.versions.bun is unavailable';
    if (node.unavailableReason) meta.toolchain.nodeUnavailableReason = node.unavailableReason;
    if (cpuModel.model === 'unknown') meta.host.cpuModelProbeRaw = cpuModel.rawProbe;
    if (currentAffinity.pinnedCpu == null) {
        meta.host.pinnedCpuUnavailableReason =
            `runner Cpus_allowed_list=${currentAffinity.mask ?? 'unavailable'} is not a single CPU`;
    }
    if (currentAffinity.unavailableReason) {
        meta.host.affinityUnavailableReason = currentAffinity.unavailableReason;
    }
    if (currentAffinity.warning) meta.host.affinityWarning = currentAffinity.warning;
    if (kernel.unavailableReason) meta.host.kernelProbeUnavailableReason = kernel.unavailableReason;
    if (perfVersion.unavailableReason) meta.pmu.perfVersionUnavailableReason = perfVersion.unavailableReason;
    if (!collectPmu) {
        meta.pmu.unavailableReason =
            'PMU collection disabled; pass --pmu to collect PRD 3.2 instructions-first arbitration metrics';
        meta.pmu.arbitrationMetricUnavailableReason =
            'instructions were not collected because --pmu was not provided';
    }
    return meta;
}

function winnerForRatio(ratio) {
    if (!Number.isFinite(ratio)) return 'unknown';
    if (ratio < 0.95) return 'zjs';
    if (ratio > 1.05) return 'qjs';
    return 'tie';
}

function formatMs(value) {
    return value.toFixed(3).padStart(10);
}

function formatRatio(value) {
    return Number.isFinite(value) ? value.toFixed(2).padStart(8) : 'Infinity'.padStart(8);
}

function listCases() {
    const suite = activeSuite();
    console.log(`Suite: ${suiteName} (${suite.description})`);
    console.log();
    console.log('Categories:');
    for (const category of suite.categories()) console.log(`  - ${category}`);
    console.log();
    console.log('Cases:');
    for (const item of suite.cases) {
        console.log(`${item.name.padEnd(24)} ${item.category.padEnd(14)} QuickJS: ${item.quickjsName}`);
    }
}

function activeSuite() {
    const suite = suites[suiteName];
    if (!suite) fail(`error: unknown suite: ${suiteName}`);
    return suite;
}

function selectedCaseList() {
    const suite = activeSuite();
    let selected = suite.cases;
    if (selectedCases.length !== 0) {
        selected = selectedCases.map((name) => {
            const found = suite.cases.find((item) => item.name === name || item.quickjsName === name);
            if (!found) fail(`error: unknown case: ${name}`);
            return found;
        });
    }

    if (selectedCategories.length !== 0) {
        const validCategories = new Set(suite.categories());
        for (const category of selectedCategories) {
            if (!validCategories.has(category)) fail(`error: unknown category: ${category}`);
        }
        const categorySet = new Set(selectedCategories);
        selected = selected.filter((item) => categorySet.has(item.category));
    }

    if (selected.length === 0) fail('error: no microbench cases selected');
    return selected;
}

function makeUnsupportedRow(item, reason) {
    return {
        name: item.name,
        quickjsName: item.quickjsName,
        category: item.category,
        expectedStatus: item.expectedStatus,
        status: 'unsupported',
        reason,
        notes: item.notes,
        validation: {
            stdoutMatch: null,
            stderrMatch: null,
            exitCodeMatch: null,
            exitCode: null,
            unavailableReason: reason,
        },
        ...unavailableCaseMeasurements(reason),
    };
}

function buildContractVerdict(report) {
    const declaredOrders = report.meta.sampling.timed.sampleOrders.map((order) => order.split('->'));
    const executedRows = report.cases.filter((row) => row.status === 'ok' && Array.isArray(row.executedOrders));
    // The sample contract is evaluated against every compatible case: one bad
    // case is enough to invalidate the headline.
    const perCase = executedRows.map((row) =>
        validateSampleContract(
            {
                samples: report.iters,
                declaredOrders,
                executedOrders: row.executedOrders.map((order) => (Array.isArray(order) ? order : String(order).split('->'))),
            },
            policy,
        ),
    );
    const sampleFailures = perCase.filter((result) => !result.ok);
    const sampleContract = sampleFailures.length === 0
        ? (perCase[0] ?? validateSampleContract({ samples: report.iters, declaredOrders, executedOrders: declaredOrders }, policy))
        : {
            ...sampleFailures[0],
            failingCases: executedRows.map((row, index) => (perCase[index].ok ? null : row.name)).filter(Boolean),
        };
    const warmupContract = formalMode ? validateWarmupContract(warmup, policy) : { ok: true, violations: [] };
    const verdict = aggregateVerdict([sampleContract, warmupContract]);
    return {
        policyRef: policyReference(policy),
        formalMode,
        diagnosticMode,
        sampleContract,
        warmupContract,
        ...verdict,
    };
}

function makeReport(rows, selected, meta) {
    const compatible = rows.filter((row) => row.status === 'ok');
    const validationFailures = rows.filter((row) => row.expectedStatus === 'supported' && row.status !== 'ok');
    const ratios = compatible.map((row) => row.ratio).filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    const pairedRatios = compatible
        .map((row) => row.paired?.geomean)
        .filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    const startupAdjustedRatios = compatible
        .map((row) => row.startupAdjusted?.ratio)
        .filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    const pairedGeomean = pairedRatios.length === 0 ? null : geometricMean(pairedRatios);
    const report = {
        tool: 'zjs-microbench',
        suite: suiteName,
        timestamp: new Date().toISOString(),
        qjs: qjsBin,
        zjs: zjsBin,
        iters,
        warmup,
        selected: selected.length,
        meta,
        summary: {
            compatible: compatible.length,
            unsupported: rows.filter((row) => row.status === 'unsupported').length,
            skipped: rows.filter((row) => row.status === 'skipped').length,
            invalid: rows.filter((row) => row.status === 'invalid').length,
            failed: validationFailures.length,
            zjsFaster: compatible.filter((row) => row.winner === 'zjs').length,
            qjsFaster: compatible.filter((row) => row.winner === 'qjs').length,
            nearTie: compatible.filter((row) => row.winner === 'tie').length,
            geometricMean: ratios.length === 0 ? null : geometricMean(ratios),
            geometricMeanIsArbitration: false,
            pairedGeomean,
            primaryMetric: 'pairedGeomean',
            primaryRatio: pairedGeomean,
            startupAdjustedGeometricMean: startupAdjustedRatios.length === 0 ? null : geometricMean(startupAdjustedRatios),
            startupAdjustedGeometricMeanIsArbitration: false,
            compatibilityMetric: true,
            routePriorityMetric: false,
        },
        cases: rows,
    };

    report.contract = buildContractVerdict(report);
    report.complete = report.contract.complete && !diagnosticMode;
    report.headline = report.complete ? pairedGeomean : null;
    if (!report.complete) {
        // Fail closed: the aggregate is removed, not annotated. A warning next
        // to a published headline is the exact failure mode P7-70 removes.
        report.summary.pairedGeomean = null;
        report.summary.primaryRatio = null;
        report.summary.geometricMean = null;
        report.summary.startupAdjustedGeometricMean = null;
        report.summary.headlineVoidReason = diagnosticMode
            ? 'diagnostic run: headlines are nulled by construction'
            : `measurement contract violated (${report.contract.errorClass}): ` +
              report.contract.violations.map((v) => v.rule).join(', ');
    }
    return report;
}

function measureStartupBaseline(scriptDir) {
    const script = path.join(scriptDir, '__startup_empty.js');
    fs.writeFileSync(script, '');
    const expected = runBinary('qjs', qjsBin, script, true);
    const actual = runBinary('zjs', zjsBin, script, true);
    const validation = validationResult(expected, actual);
    const note = 'informational only; not the arbitration metric (PRD 5.2)';
    if (!validationPassed(validation)) {
        return {
            status: 'invalid',
            reason: summarizeMismatch(expected, actual),
            validation,
            note,
        };
    }
    const result = benchPair(qjsBin, zjsBin, script);
    if (result.status !== 'ok') {
        const failure = result.failure;
        return {
            status: 'skipped',
            reason:
                `bench ${failure.phase} ${failure.engine} rc=${failure.exitCode}` +
                (failure.spawnError ? ` (${failure.spawnError})` : ''),
            qjs: { samples: result.qjsSamples },
            zjs: { samples: result.zjsSamples },
            pairs: result.pairs,
            warmupOrders: result.warmupOrders,
            validation,
            note,
        };
    }
    const qjsStats = stats(result.qjsSamples);
    const zjsStats = stats(result.zjsSamples);
    const ratio = qjsStats.avg > 0 ? zjsStats.avg / qjsStats.avg : Number.POSITIVE_INFINITY;
    return {
        status: 'ok',
        qjs: qjsStats,
        zjs: zjsStats,
        ratio,
        winner: winnerForRatio(ratio),
        pairs: result.pairs,
        paired: pairedStats(result.pairs),
        warmupOrders: result.warmupOrders,
        validation,
        note,
    };
}

function startupAdjustedAverage(measured, baseline) {
    if (!measured || !baseline) return null;
    const adjusted = measured.avg - baseline.avg;
    return adjusted > 0 ? adjusted : null;
}

function addStartupAdjustedRows(rows, startupBaseline) {
    if (startupBaseline?.status !== 'ok') return;
    for (const row of rows) {
        if (row.status !== 'ok') continue;
        const qjsAvg = startupAdjustedAverage(row.qjs, startupBaseline.qjs);
        const zjsAvg = startupAdjustedAverage(row.zjs, startupBaseline.zjs);
        const ratio = qjsAvg != null && zjsAvg != null ? zjsAvg / qjsAvg : null;
        row.startupAdjusted = {
            qjsAvg,
            zjsAvg,
            ratio,
            winner: Number.isFinite(ratio) ? winnerForRatio(ratio) : 'unknown',
        };
    }
}

function printTable(report) {
    const rows = includeUnsupported
        ? report.cases
        : report.cases.filter((row) => row.status === 'ok' || row.status === 'skipped' || row.expectedStatus === 'supported');
    const nameWidth = Math.max('case'.length, ...rows.map((row) => row.name.length));
    const quickjsWidth = Math.max('quickjs_case'.length, ...rows.map((row) => row.quickjsName.length));
    const categoryWidth = Math.max('category'.length, ...rows.map((row) => row.category.length));

    console.log('== zjs microbench ==');
    console.log(
        `${'case'.padEnd(nameWidth)}  ${'category'.padEnd(categoryWidth)}  ${'quickjs_case'.padEnd(quickjsWidth)}  ${'qjs_avg'.padStart(10)}  ${'zjs_avg'.padStart(10)}  ${'zjs/qjs'.padStart(8)}  status`,
    );
    console.log(
        `${'-'.repeat(nameWidth)}  ${'-'.repeat(categoryWidth)}  ${'-'.repeat(quickjsWidth)}  ${'-'.repeat(10)}  ${'-'.repeat(10)}  ${'-'.repeat(8)}  ${'-'.repeat(12)}`,
    );
    for (const row of rows) {
        if (row.status !== 'ok') {
            console.log(
                `${row.name.padEnd(nameWidth)}  ${row.category.padEnd(categoryWidth)}  ${row.quickjsName.padEnd(quickjsWidth)}  ${'-'.padStart(10)}  ${'-'.padStart(10)}  ${'-'.padStart(8)}  ${row.status} (${row.reason})`,
            );
            continue;
        }
        console.log(
            `${row.name.padEnd(nameWidth)}  ${row.category.padEnd(categoryWidth)}  ${row.quickjsName.padEnd(quickjsWidth)}  ${formatMs(row.qjs.avg)}  ${formatMs(row.zjs.avg)}  ${formatRatio(row.ratio)}  ${row.winner}`,
        );
    }

    console.log();
    console.log(`compatible cases: ${report.summary.compatible}/${report.selected}`);
    console.log(`unsupported cases: ${report.summary.unsupported}`);
    console.log(`skipped cases: ${report.summary.skipped}`);
    console.log(`invalid cases: ${report.summary.invalid}`);
    console.log(`validation failures: ${report.summary.failed}`);
    if (report.summary.pairedGeomean != null) {
        console.log(`paired geomean (zjs/qjs, primary): ${report.summary.pairedGeomean.toFixed(2)}`);
    }
    if (report.summary.geometricMean != null) {
        console.log(`legacy ratio-of-averages geomean (zjs/qjs): ${report.summary.geometricMean.toFixed(2)}`);
    }
    if (report.summary.startupAdjustedGeometricMean != null) {
        console.log(`startup-adjusted geometric mean (informational): ${report.summary.startupAdjustedGeometricMean.toFixed(2)}`);
    }
    if (report.startupBaseline?.status === 'ok') {
        console.log(
            `startup baseline: qjs ${formatMs(report.startupBaseline.qjs.avg)} ms, ` +
            `zjs ${formatMs(report.startupBaseline.zjs.avg)} ms, ` +
            `zjs/qjs ${formatRatio(report.startupBaseline.ratio).trim()}`,
        );
    } else if (report.startupBaseline) {
        console.log(`startup baseline: ${report.startupBaseline.status} (${report.startupBaseline.reason})`);
    }
}

function hasValidationFailures(report) {
    return report.summary.failed !== 0;
}

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--iters': {
            const value = args[++i];
            if (value == null) fail('error: --iters requires a value');
            iters = parseInteger(value, Number.NaN);
            if (!Number.isFinite(iters) || iters <= 0) fail('error: iters must be > 0');
            break;
        }
        case '--warmup': {
            const value = args[++i];
            if (value == null) fail('error: --warmup requires a value');
            warmup = parseInteger(value, Number.NaN);
            if (!Number.isFinite(warmup) || warmup < 0) fail('error: warmup must be >= 0');
            break;
        }
        case '--formal':
            formalMode = true;
            break;
        case '--diagnostic':
            diagnosticMode = true;
            break;
        case '--case': {
            const value = args[++i];
            if (value == null) fail('error: --case requires a value');
            selectedCases.push(value);
            break;
        }
        case '--category': {
            const value = args[++i];
            if (value == null) fail('error: --category requires a value');
            selectedCategories.push(value);
            break;
        }
        case '--suite': {
            const value = args[++i];
            if (value == null) fail('error: --suite requires a value');
            suiteName = value;
            break;
        }
        case '--include-unsupported':
            includeUnsupported = true;
            break;
        case '--zjs-only':
        case '--self':
            zjsOnly = true;
            break;
        case '--json':
            emitJson = true;
            break;
        case '--output': {
            const value = args[++i];
            if (value == null) fail('error: --output requires a path');
            outputPath = value;
            break;
        }
        case '--emit-scripts': {
            const value = args[++i];
            if (value == null) fail('error: --emit-scripts requires a directory');
            emitScriptsDir = path.resolve(process.cwd(), value);
            break;
        }
        case '--cpu': {
            const value = args[++i];
            if (value == null) fail('error: --cpu requires a value');
            const parsed = Number(value);
            if (!Number.isInteger(parsed) || parsed < 0) fail('error: --cpu must be a non-negative integer');
            requestedCpu = parsed;
            break;
        }
        case '--pmu':
            collectPmu = true;
            break;
        case '--pmu-runs': {
            const value = args[++i];
            if (value == null) fail('error: --pmu-runs requires a value');
            const parsed = Number(value);
            if (!Number.isInteger(parsed) || parsed <= 0) fail('error: --pmu-runs must be a positive integer');
            pmuRuns = parsed;
            break;
        }
        case '--teardown-matched':
            teardownMatched = true;
            break;
        case '--zjs': {
            const value = args[++i];
            if (value == null) fail('error: --zjs requires a path');
            zjsBin = value;
            break;
        }
        case '--qjs': {
            const value = args[++i];
            if (value == null) fail('error: --qjs requires a path');
            qjsBin = value;
            break;
        }
        case '--list':
            shouldList = true;
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default:
            fail(`error: unknown option: ${arg}`);
    }
}

activeSuite();
if (shouldList) {
    listCases();
    process.exit(0);
}
initializeAffinity();

// P7-70 A1: fail closed *before* any process is spawned when the requested
// sampling design cannot be balanced at all. An odd sample count has voided a
// headline twice already (`run_direct.py --samples 5`, Phase 6 same-runtime
// 3 qjs-first / 2 zjs-first), each time behind a warning that was ignored.
const preflightSampleContract = validateSampleContract(
    {
        samples: iters,
        declaredOrders: orderAudit(iters).sampleOrders.map((order) => order.split('->')),
        executedOrders: orderAudit(iters).sampleOrders.map((order) => order.split('->')),
    },
    policy,
);
if (!preflightSampleContract.ok && !diagnosticMode) {
    for (const violation of preflightSampleContract.violations) {
        console.error(`error: ${violation.rule}: ${violation.detail}`);
    }
    console.error('error: SampleBalanceError: complete=false, headline=null, pairedGeomean=null');
    process.exit(CONTRACT_EXIT_CODES.sampleBalance);
}
if (formalMode) {
    const warmupContract = validateWarmupContract(warmup, policy);
    if (!warmupContract.ok && !diagnosticMode) {
        for (const violation of warmupContract.violations) {
            console.error(`error: ${violation.rule}: ${violation.detail}`);
        }
        console.error('error: SampleBalanceError: complete=false, headline=null, pairedGeomean=null');
        process.exit(CONTRACT_EXIT_CODES.sampleBalance);
    }
}
if (collectPmu && pmuRuns % 2 !== 0) {
    console.error(
        `warning: --pmu-runs ${pmuRuns} produces an unbalanced first-position count; ` +
        'the artifact records orderBalanced=false',
    );
}
// Fail closed when PMU collection is requested on an unpinned runner. `--cpu N`
// only asserts affinity now (it no longer wraps timed spawns in taskset), so the
// pin has to come from the caller. On heterogeneous hosts (this box is aarch64
// big.LITTLE: Cortex-X925 + Cortex-A725) an unpinned run lets rounds land on
// different core types, and `perf stat` then reports counts from distinct PMUs
// that must not be averaged together. instructions is the PRD 3.2 rank-1
// arbitration metric, so a silently mixed number is worse than no number.
if (collectPmu && currentAffinity.affinitySource !== 'inherited') {
    fail(
        'error: --pmu requires the runner to be pinned to a single CPU, but the measured ' +
        `Cpus_allowed_list is ${currentAffinity.mask ?? 'unavailable'}. ` +
        'Re-run under `taskset -c <cpu>` (see PRD 5.3), or drop --pmu.',
    );
}

ensureExecutable(zjsBin, 'zjs', "run 'zig build qjs -Doptimize=ReleaseFast' first, or set QJS_ZIG");
if (zjsOnly) {
    qjsBin = zjsBin;
} else {
    ensureExecutable(qjsBin, 'qjs (C)', 'build QuickJS first, or set QJS');
}

const selected = selectedCaseList();
const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zjs-microbench-'));
if (emitScriptsDir) fs.mkdirSync(emitScriptsDir, { recursive: true });
try {
    const rows = [];
    for (const item of selected) {
        if (!item.source) {
            rows.push(makeUnsupportedRow(item, item.notes || 'no zjs-compatible source registered'));
            continue;
        }

        const script = path.join(emitScriptsDir || tempDir, `${item.name}.js`);
        fs.writeFileSync(script, `${item.source}\n`);

        const expected = runBinary('qjs', qjsBin, script, true);
        const actual = runBinary('zjs', zjsBin, script, true);
        const validation = validationResult(expected, actual);

        if (!validationPassed(validation)) {
            const reason = summarizeMismatch(expected, actual);
            rows.push({
                name: item.name,
                quickjsName: item.quickjsName,
                category: item.category,
                expectedStatus: item.expectedStatus,
                status: 'invalid',
                reason,
                notes: item.notes,
                validation,
                qjsCheck: validationCheckSnapshot(expected),
                zjsCheck: validationCheckSnapshot(actual),
                ...unavailableCaseMeasurements(`validation failed: ${reason}`),
            });
            continue;
        }

        const result = benchPair(qjsBin, zjsBin, script);
        if (result.status !== 'ok') {
            const failure = result.failure;
            const reason =
                `bench ${failure.phase} ${failure.engine} rc=${failure.exitCode}` +
                (failure.spawnError ? ` (${failure.spawnError})` : '');
            rows.push({
                name: item.name,
                quickjsName: item.quickjsName,
                category: item.category,
                expectedStatus: item.expectedStatus,
                status: 'skipped',
                reason,
                notes: item.notes,
                validation,
                qjs: { samples: result.qjsSamples },
                zjs: { samples: result.zjsSamples },
                pairs: result.pairs,
                warmupOrders: result.warmupOrders,
                executedOrders: result.executedOrders,
                ...unavailableCaseMeasurements(reason),
            });
            continue;
        }

        const qjsStats = stats(result.qjsSamples);
        const zjsStats = stats(result.zjsSamples);
        const ratio = qjsStats.avg > 0 ? zjsStats.avg / qjsStats.avg : Number.POSITIVE_INFINITY;
        const pmu = collectCasePmu(qjsBin, zjsBin, script);
        const peakRssKb = collectCasePeakRss(qjsBin, zjsBin, script);
        rows.push({
            name: item.name,
            quickjsName: item.quickjsName,
            category: item.category,
            expectedStatus: item.expectedStatus,
            status: 'ok',
            notes: item.notes,
            validation,
            qjs: qjsStats,
            zjs: zjsStats,
            ratio,
            winner: winnerForRatio(ratio),
            pairs: result.pairs,
            paired: pairedStats(result.pairs),
            warmupOrders: result.warmupOrders,
            executedOrders: result.executedOrders,
            pmu,
            peakRssKb,
            allocations: unavailableAllocationMetric('allocation count'),
            allocatedBytes: unavailableAllocationMetric('allocated bytes'),
        });
    }

    const startupBaseline = measureStartupBaseline(tempDir);
    addStartupAdjustedRows(rows, startupBaseline);
    const report = makeReport(rows, selected, collectMetadata());
    if (zjsOnly) report.baseline = 'zjs-only';
    report.startupBaseline = startupBaseline;
    const json = `${JSON.stringify(report, null, 2)}\n`;
    if (outputPath) {
        const resolvedOutput = path.resolve(process.cwd(), outputPath);
        fs.mkdirSync(path.dirname(resolvedOutput), { recursive: true });
        fs.writeFileSync(resolvedOutput, json);
    }
    if (emitJson) {
        process.stdout.write(json);
    } else {
        printTable(report);
    }
    if (hasValidationFailures(report)) process.exit(CONTRACT_EXIT_CODES.validationFailure);
    if (!report.contract.complete) {
        for (const violation of report.contract.violations) {
            console.error(`error: ${violation.rule}: ${violation.detail}`);
        }
        console.error(`error: ${report.contract.errorClass}: complete=false, headline=null, pairedGeomean=null`);
        process.exit(report.contract.exitCode);
    }
} finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
}
