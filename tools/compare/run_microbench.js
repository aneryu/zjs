#!/usr/bin/env bun

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { performance } from 'node:perf_hooks';
import { cases, categories } from './microbench_cases.js';

const toolDir = import.meta.dir;
const root = path.resolve(toolDir, '../..');

const defaultZjs = path.join(root, 'zig-out', 'bin', 'zjs');
const defaultQjs = fs.existsSync(path.join(root, 'build', 'qjs'))
    ? path.join(root, 'build', 'qjs')
    : path.join(root, 'quickjs', 'build', 'qjs');

let zjsBin = process.env.QJS_ZIG || defaultZjs;
let qjsBin = process.env.QJS || defaultQjs;
let iters = parseInteger(process.env.BENCH_ITERS, 10);
let warmup = parseInteger(process.env.BENCH_WARMUP, 3);
let includeUnsupported = false;
let zjsOnly = false;
let emitJson = false;
let outputPath = null;
let emitScriptsDir = null;
const selectedCases = [];
const selectedCategories = [];

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
  --case NAME               Run one case; repeatable
  --category NAME           Run one category; repeatable
  --include-unsupported     Show unsupported cases in the terminal table
  --zjs-only                Use zjs for the reference column; does not require C qjs
  --json                    Print the JSON report to stdout instead of the table
  --output PATH             Write the JSON report to PATH
  --emit-scripts DIR        Write generated benchmark scripts to DIR for profiling
  --list                    List available cases and categories, then exit
  --zjs PATH                Path to zjs (default: ${zjsBin})
  --qjs PATH                Path to C qjs (default: ${qjsBin})
  -h, --help                Show this help

Environment:
  QJS_ZIG                   Path to zjs
  QJS                       Path to C qjs
  BENCH_ITERS               Default iteration count
  BENCH_WARMUP              Default warmup count`);
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

function runBinary(binary, script, captureOutput) {
    const proc = Bun.spawnSync({
        cmd: [binary, script],
        stdout: captureOutput ? 'pipe' : 'ignore',
        stderr: captureOutput ? 'pipe' : 'ignore',
    });
    return {
        stdout: captureOutput ? new TextDecoder().decode(proc.stdout) : '',
        stderr: captureOutput ? new TextDecoder().decode(proc.stderr) : '',
        exitCode: proc.exitCode ?? 0,
    };
}

function bench(binary, script) {
    for (let i = 0; i < warmup; i += 1) {
        const result = runBinary(binary, script, false);
        if (result.exitCode !== 0) return { exitCode: result.exitCode, samples: [] };
    }

    const samples = [];
    for (let i = 0; i < iters; i += 1) {
        const start = performance.now();
        const result = runBinary(binary, script, false);
        samples.push(performance.now() - start);
        if (result.exitCode !== 0) return { exitCode: result.exitCode, samples };
    }
    return { exitCode: 0, samples };
}

function stats(samples) {
    if (samples.length === 0) return null;
    const sorted = [...samples].sort((a, b) => a - b);
    const avg = sorted.reduce((sum, value) => sum + value, 0) / sorted.length;
    const median = sorted.length % 2 === 1
        ? sorted[(sorted.length - 1) / 2]
        : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2;
    const variance = sorted.reduce((sum, value) => sum + (value - avg) ** 2, 0) / sorted.length;
    return {
        samples,
        avg,
        median,
        min: sorted[0],
        max: sorted[sorted.length - 1],
        stdev: Math.sqrt(variance),
    };
}

function geometricMean(values) {
    const sum = values.reduce((acc, value) => acc + Math.log(value), 0);
    return Math.exp(sum / values.length);
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
    console.log('Categories:');
    for (const category of categories()) console.log(`  - ${category}`);
    console.log();
    console.log('Cases:');
    for (const item of cases) {
        console.log(`${item.name.padEnd(24)} ${item.category.padEnd(14)} QuickJS: ${item.quickjsName}`);
    }
}

function selectedCaseList() {
    let selected = cases;
    if (selectedCases.length !== 0) {
        selected = selectedCases.map((name) => {
            const found = cases.find((item) => item.name === name || item.quickjsName === name);
            if (!found) fail(`error: unknown case: ${name}`);
            return found;
        });
    }

    if (selectedCategories.length !== 0) {
        const validCategories = new Set(categories());
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
    };
}

function makeReport(rows, selected) {
    const compatible = rows.filter((row) => row.status === 'ok');
    const validationFailures = rows.filter((row) => row.expectedStatus === 'supported' && row.status !== 'ok');
    const ratios = compatible.map((row) => row.ratio).filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    const startupAdjustedRatios = compatible
        .map((row) => row.startupAdjusted?.ratio)
        .filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    return {
        tool: 'zjs-microbench',
        timestamp: new Date().toISOString(),
        qjs: qjsBin,
        zjs: zjsBin,
        iters,
        warmup,
        selected: selected.length,
        summary: {
            compatible: compatible.length,
            unsupported: rows.filter((row) => row.status === 'unsupported').length,
            skipped: rows.filter((row) => row.status === 'skipped').length,
            failed: validationFailures.length,
            zjsFaster: compatible.filter((row) => row.winner === 'zjs').length,
            qjsFaster: compatible.filter((row) => row.winner === 'qjs').length,
            nearTie: compatible.filter((row) => row.winner === 'tie').length,
            geometricMean: ratios.length === 0 ? null : geometricMean(ratios),
            startupAdjustedGeometricMean: startupAdjustedRatios.length === 0 ? null : geometricMean(startupAdjustedRatios),
        },
        cases: rows,
    };
}

function measureStartupBaseline(tempDir) {
    const script = path.join(tempDir, '__startup_empty.js');
    fs.writeFileSync(script, '');
    const qjsResult = bench(qjsBin, script);
    const zjsResult = bench(zjsBin, script);
    if (qjsResult.exitCode !== 0 || zjsResult.exitCode !== 0) {
        return {
            status: 'skipped',
            reason: `bench rc qjs=${qjsResult.exitCode}, zjs=${zjsResult.exitCode}`,
            qjs: { samples: qjsResult.samples },
            zjs: { samples: zjsResult.samples },
        };
    }
    const qjsStats = stats(qjsResult.samples);
    const zjsStats = stats(zjsResult.samples);
    const ratio = qjsStats.avg > 0 ? zjsStats.avg / qjsStats.avg : Number.POSITIVE_INFINITY;
    return {
        status: 'ok',
        qjs: qjsStats,
        zjs: zjsStats,
        ratio,
        winner: winnerForRatio(ratio),
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
    console.log(`validation failures: ${report.summary.failed}`);
    if (report.summary.geometricMean != null) {
        console.log(`geometric mean (zjs/qjs): ${report.summary.geometricMean.toFixed(2)}`);
    }
    if (report.summary.startupAdjustedGeometricMean != null) {
        console.log(`startup-adjusted geometric mean (zjs/qjs): ${report.summary.startupAdjustedGeometricMean.toFixed(2)}`);
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
            listCases();
            process.exit(0);
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default:
            fail(`error: unknown option: ${arg}`);
    }
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

        const expected = runBinary(qjsBin, script, true);
        const actual = runBinary(zjsBin, script, true);
        const matches =
            expected.exitCode === actual.exitCode &&
            expected.stdout === actual.stdout &&
            expected.stderr === actual.stderr;

        if (!matches) {
            rows.push({
                ...makeUnsupportedRow(item, summarizeMismatch(expected, actual)),
                qjsCheck: expected,
                zjsCheck: actual,
            });
            continue;
        }

        const qjsResult = bench(qjsBin, script);
        const zjsResult = bench(zjsBin, script);
        if (qjsResult.exitCode !== 0 || zjsResult.exitCode !== 0) {
            rows.push({
                name: item.name,
                quickjsName: item.quickjsName,
                category: item.category,
                expectedStatus: item.expectedStatus,
                status: 'skipped',
                reason: `bench rc qjs=${qjsResult.exitCode}, zjs=${zjsResult.exitCode}`,
                notes: item.notes,
                qjs: { samples: qjsResult.samples },
                zjs: { samples: zjsResult.samples },
            });
            continue;
        }

        const qjsStats = stats(qjsResult.samples);
        const zjsStats = stats(zjsResult.samples);
        const ratio = qjsStats.avg > 0 ? zjsStats.avg / qjsStats.avg : Number.POSITIVE_INFINITY;
        rows.push({
            name: item.name,
            quickjsName: item.quickjsName,
            category: item.category,
            expectedStatus: item.expectedStatus,
            status: 'ok',
            notes: item.notes,
            qjs: qjsStats,
            zjs: zjsStats,
            ratio,
            winner: winnerForRatio(ratio),
        });
    }

    const startupBaseline = measureStartupBaseline(tempDir);
    addStartupAdjustedRows(rows, startupBaseline);
    const report = makeReport(rows, selected);
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
    if (hasValidationFailures(report)) process.exit(1);
} finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
}
