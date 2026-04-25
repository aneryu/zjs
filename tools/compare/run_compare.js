#!/usr/bin/env bun

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const toolDir = import.meta.dir;
const root = path.resolve(toolDir, '../..');
const smokeDir = path.join(root, 'tests', 'zig-smoke');
const configPath = path.join(toolDir, 'config.json');

const config = loadConfig();

const zigBin = process.env.QJS_ZIG || path.join(root, 'zig-out', 'bin', 'zjs');
const cBin =
    process.env.QJS ||
    (fs.existsSync(path.join(root, 'build', 'qjs'))
        ? path.join(root, 'build', 'qjs')
        : path.join(root, 'quickjs', 'build', 'qjs'));

let mode = 'both';
let iters = parseInteger(process.env.BENCH_ITERS, 5);
let warmup = parseInteger(process.env.BENCH_WARMUP, 1);
const selectedScripts = [];
const comparableScripts = [];
const divergeList = [];
const knownFailList = [];
let allowKnownFail = false;
let includeStableOnly = false;
let includeAll = false;

function loadConfig() {
    try {
        const raw = fs.readFileSync(configPath, 'utf8');
        const parsed = JSON.parse(raw);
        const knownFail = Array.isArray(parsed.known_fail) ? parsed.known_fail : [];
        const manifest = typeof parsed.manifest === 'string' ? loadManifest(parsed.manifest) : [];
        const stable = manifest.length
            ? manifest.filter((entry) => !knownFail.includes(entry))
            : (Array.isArray(parsed.stable) ? parsed.stable : []);
        return {
            stable,
            known_fail: knownFail,
        };
    } catch (err) {
        return {
            stable: [],
            known_fail: [],
        };
    }
}

function loadManifest(manifestPath) {
    const absolutePath = path.resolve(root, manifestPath);
    const raw = fs.readFileSync(absolutePath, 'utf8');
    return raw
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line.length > 0 && !line.startsWith('#'));
}

function parseInteger(value, fallback) {
    if (value == null || value === '') return fallback;
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : fallback;
}

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'run_compare.js')} [options]

Options:
  --functional-only         Only compare stdout/stderr and exit status
  --performance-only        Only benchmark scripts with matching behaviour
  --iters N                 Benchmark iterations per binary (default: ${iters})
  --warmup N                Warmup runs per binary before timing (default: ${warmup})
  --script PATH             Compare a specific script (repeatable)
  --stable                  Use configured stable script set (default when no script specified)
  --all                     Compare all .js scripts under tests/zig-smoke
  --known-fail-ok           Do not fail process on known failures
  --list                     List stable/known-fail script sets and exit
  -h, --help                Show this help

Environment:
  QJS_ZIG                   Path to zjs binary (default: ${zigBin})
  QJS                       Path to C qjs binary (default: ${cBin})
  BENCH_ITERS               Default iteration count for benchmarking
  BENCH_WARMUP              Default warmup count for benchmarking`);
}

function resolveScript(input) {
    const direct = path.resolve(process.cwd(), input);
    if (fs.existsSync(direct) && fs.statSync(direct).isFile()) {
        return direct;
    }

    const relativeToSmoke = path.join(smokeDir, input);
    if (fs.existsSync(relativeToSmoke) && fs.statSync(relativeToSmoke).isFile()) {
        return relativeToSmoke;
    }

    return null;
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function ensureExecutable(filePath, label, hint) {
    if (!fs.existsSync(filePath)) {
        fail(`error: ${label} not found at ${filePath}\n       ${hint}`);
    }
    try {
        fs.accessSync(filePath, fs.constants.X_OK);
    } catch {
        fail(`error: ${label} is not executable at ${filePath}\n       ${hint}`);
    }
}

function runBinary(binary, script, captureOutput = true) {
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

function firstDifferenceLine(expected, actual) {
    const expectedLines = expected.split('\n');
    const actualLines = actual.split('\n');
    const limit = Math.max(expectedLines.length, actualLines.length);
    for (let i = 0; i < limit; i += 1) {
        if ((expectedLines[i] ?? '') !== (actualLines[i] ?? '')) {
            return i + 1;
        }
    }
    return 0;
}

function printStreamDiff(label, expected, actual) {
    if (expected === actual) return;
    const diffLine = firstDifferenceLine(expected, actual);
    console.log(`    ${label} differs${diffLine > 0 ? ` at line ${diffLine}` : ''}`);
    console.log('      expected:');
    for (const line of expected.split('\n')) {
        console.log(`        ${line}`);
    }
    console.log('      actual:');
    for (const line of actual.split('\n')) {
        console.log(`        ${line}`);
    }
}

function collectDefaultScripts() {
    if (includeAll) {
        return fs
            .readdirSync(smokeDir)
            .filter((entry) => entry.endsWith('.js'))
            .map((entry) => path.join(smokeDir, entry))
            .sort((a, b) => a.localeCompare(b));
    }

    const used = includeStableOnly || (!selectedScripts.length && !includeAll);
    if (used) {
        const set = new Set(config.stable);
        return config.stable.map((entry) => resolveScript(entry)).filter(Boolean);
    }

    return config.stable.map((entry) => resolveScript(entry)).filter(Boolean);
}

function formatMs(value) {
    return value.toFixed(3).padStart(10);
}

function formatRatio(value) {
    return Number.isFinite(value) ? value.toFixed(2).padStart(8) : 'Infinity'.padStart(8);
}

function isKnownFail(name) {
    return config.known_fail.includes(name);
}

function runFunctional() {
    console.log('== Functional comparison ==');

    let pass = 0;
    let failCount = 0;
    let knownCount = 0;

    for (const script of selectedScripts) {
        const name = path.basename(script);
        const expected = runBinary(cBin, script, true);
        const actual = runBinary(zigBin, script, true);

        const matches =
            expected.exitCode === actual.exitCode &&
            expected.stdout === actual.stdout &&
            expected.stderr === actual.stderr;

        if (matches) {
            pass += 1;
            comparableScripts.push(script);
            console.log(`ok   ${name}`);
            continue;
        }

        if (isKnownFail(name)) {
            knownCount += 1;
            knownFailList.push(name);
            console.log(`KNOWN  ${name} (rc ${expected.exitCode} vs ${actual.exitCode})`);
            continue;
        }

        failCount += 1;
        divergeList.push(name);
        console.log(`FAIL ${name} (rc ${expected.exitCode} vs ${actual.exitCode})`);
        printStreamDiff('stdout', expected.stdout, actual.stdout);
        printStreamDiff('stderr', expected.stderr, actual.stderr);
    }

    console.log();
    console.log(`functional summary: ${pass} passed, ${failCount} failed, ${knownCount} known-fail`);
    if (failCount !== 0) {
        console.log(`diverged: ${divergeList.join(' ')}`);
    }
    if (knownCount !== 0) {
        console.log(`known-fail: ${knownFailList.join(' ')}`);
    }
    console.log();

    return failCount;
}

function bench(binary, script) {
    for (let i = 0; i < warmup; i += 1) {
        runBinary(binary, script, false);
    }

    const samples = [];
    for (let i = 0; i < iters; i += 1) {
        const start = performance.now();
        const result = runBinary(binary, script, false);
        const elapsedMs = performance.now() - start;
        samples.push(elapsedMs);
        if (result.exitCode !== 0) {
            return { exitCode: result.exitCode, samples };
        }
    }

    return { exitCode: 0, samples };
}

function average(values) {
    return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function geometricMean(values) {
    const sum = values.reduce((acc, value) => acc + Math.log(value), 0);
    return Math.exp(sum / values.length);
}

function runPerformance() {
    const perfScripts = mode === 'performance' ? [...selectedScripts] : [...comparableScripts];

    console.log('== Performance comparison ==');
    if (perfScripts.length === 0) {
        console.log('No scripts eligible for performance benchmarking.');
        console.log();
        return 0;
    }

    const rows = [];
    const ratios = [];
    let zigFaster = 0;
    let cFaster = 0;
    let nearTie = 0;

    for (const script of perfScripts) {
        const name = path.basename(script);
        const cResult = bench(cBin, script);
        const zigResult = bench(zigBin, script);

        if (cResult.exitCode !== 0 || zigResult.exitCode !== 0) {
            rows.push({ name, status: `skip(rc c=${cResult.exitCode}, zig=${zigResult.exitCode})` });
            continue;
        }

        const cAvg = average(cResult.samples);
        const zigAvg = average(zigResult.samples);
        const ratio = cAvg > 0 ? zigAvg / cAvg : Number.POSITIVE_INFINITY;
        ratios.push(ratio);

        let winner = 'tie';
        if (ratio < 0.95) {
            winner = 'zig';
            zigFaster += 1;
        } else if (ratio > 1.05) {
            winner = 'c';
            cFaster += 1;
        } else {
            nearTie += 1;
        }

        rows.push({ name, cAvg, zigAvg, ratio, winner });
    }

    const nameWidth = Math.max('script'.length, ...rows.map((row) => row.name.length));
    console.log(
        `${'script'.padEnd(nameWidth)}  ${'c_ms'.padStart(10)}  ${'zig_ms'.padStart(10)}  ${'zig/c'.padStart(8)}  winner`,
    );
    console.log(`${'-'.repeat(nameWidth)}  ${'-'.repeat(10)}  ${'-'.repeat(10)}  ${'-'.repeat(8)}  ${'-'.repeat(12)}`);

    for (const row of rows) {
        if ('status' in row) {
            console.log(
                `${row.name.padEnd(nameWidth)}  ${'-'.padStart(10)}  ${'-'.padStart(10)}  ${'-'.padStart(8)}  ${row.status}`,
            );
            continue;
        }
        console.log(
            `${row.name.padEnd(nameWidth)}  ${formatMs(row.cAvg)}  ${formatMs(row.zigAvg)}  ${formatRatio(row.ratio)}  ${row.winner}`,
        );
    }

    console.log();
    console.log(`bench summary: zig faster ${zigFaster}, c faster ${cFaster}, near tie ${nearTie}`);
    if (ratios.length > 0) {
        console.log(`geometric mean (zig/c): ${geometricMean(ratios).toFixed(2)}`);
    }
    console.log();

    return 0;
}

function listConfig() {
    console.log('Stable scripts:');
    for (const name of config.stable) {
        console.log(`  - ${name}`);
    }
    console.log('Known-fail scripts:');
    for (const name of config.known_fail) {
        console.log(`  - ${name}`);
    }
    console.log();
}

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--functional-only':
            mode = 'functional';
            break;
        case '--performance-only':
            mode = 'performance';
            break;
        case '--stable':
            includeStableOnly = true;
            includeAll = false;
            break;
        case '--all':
            includeAll = true;
            includeStableOnly = false;
            break;
        case '--known-fail-ok':
            allowKnownFail = true;
            break;
        case '--list':
            listConfig();
            process.exit(0);
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
        case '--script': {
            const value = args[++i];
            if (value == null) fail('error: --script requires a path');
            const scriptPath = resolveScript(value);
            if (!scriptPath) fail(`error: script not found: ${value}`);
            selectedScripts.push(scriptPath);
            break;
        }
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default: {
            const scriptPath = resolveScript(arg);
            if (!scriptPath) fail(`error: unknown option or script not found: ${arg}`);
            selectedScripts.push(scriptPath);
            break;
        }
    }
}

ensureExecutable(zigBin, 'zjs', "run 'zig build qjs' first, or set QJS_ZIG");
ensureExecutable(cBin, 'qjs (C)', 'build it first, or set QJS');

if (selectedScripts.length === 0) {
    selectedScripts.push(...collectDefaultScripts());
}

if (selectedScripts.length === 0) {
    fail('error: no scripts to compare');
}

if (selectedScripts.some((item) => !fs.existsSync(item))) {
    fail('error: selected script missing');
}

if (allowKnownFail) {
    // do nothing; known failures are treated like pass for exit code only
}

let failCount = 0;
if (mode !== 'performance') {
    failCount = runFunctional();
} else {
    comparableScripts.push(...selectedScripts);
}

if (mode !== 'functional') {
    runPerformance();
}

if (mode !== 'performance' && failCount !== 0 && !allowKnownFail) {
    process.exit(1);
}
