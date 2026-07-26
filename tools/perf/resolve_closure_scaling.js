#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

const root = path.resolve(import.meta.dirname, '../..');

let zjsBin = path.join(root, 'zig-out', 'bin', 'zjs');
let qjsBin = null;
let captureCounts = [16, 64, 256];
let usesPerCapture = [1, 8];
let depths = [1, 4];
let iterations = 7;
let warmup = 3;
let emitDir = null;
let outputPath = null;
let cpu = null;
let perfStat = false;

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1])} [options]

Generate paired capture/local functions and measure whole-process compile/startup
cost. Both variants have identical nesting, declarations, references, and source
byte counts; only the declaration position changes whether the deepest function
captures each binding or resolves it locally. No generated function is called.

Options:
  --zjs PATH          zjs binary (default: ${zjsBin})
  --qjs PATH          optional QuickJS comparator
  --captures LIST     distinct binding counts (default: ${captureCounts.join(',')})
  --uses LIST         uses per binding (default: ${usesPerCapture.join(',')})
  --depths LIST       nested function depths (default: ${depths.join(',')})
  --iters N           timed paired iterations per point (default: ${iterations})
  --warmup N          warmup paired iterations per point (default: ${warmup})
  --emit-dir PATH     retain scripts and frozen binaries in PATH
  --output PATH       write JSON to PATH as well as stdout
  --cpu N             pin every measured process to logical CPU N
  --perf-stat         record instructions and cycles for every timed sample
  -h, --help          show this help
`);
}

function fail(message) {
    console.error(`error: ${message}`);
    process.exit(2);
}

function parsePositiveInteger(value, option) {
    const parsed = Number.parseInt(value, 10);
    if (!Number.isSafeInteger(parsed) || parsed <= 0) fail(`${option} requires a positive integer`);
    return parsed;
}

function parseNonnegativeInteger(value, option) {
    const parsed = Number.parseInt(value, 10);
    if (!Number.isSafeInteger(parsed) || parsed < 0) fail(`${option} requires a nonnegative integer`);
    return parsed;
}

function parsePositiveList(value, option) {
    const result = value.split(',').map((item) => parsePositiveInteger(item, option));
    if (new Set(result).size !== result.length) fail(`${option} values must be unique`);
    return result;
}

for (let i = 2; i < process.argv.length; i += 1) {
    const arg = process.argv[i];
    switch (arg) {
        case '--zjs':
            zjsBin = process.argv[++i] ?? fail('--zjs requires a path');
            break;
        case '--qjs':
            qjsBin = process.argv[++i] ?? fail('--qjs requires a path');
            break;
        case '--captures':
            captureCounts = parsePositiveList(
                process.argv[++i] ?? fail('--captures requires a list'),
                '--captures',
            );
            break;
        case '--uses':
            usesPerCapture = parsePositiveList(
                process.argv[++i] ?? fail('--uses requires a list'),
                '--uses',
            );
            break;
        case '--depths':
            depths = parsePositiveList(
                process.argv[++i] ?? fail('--depths requires a list'),
                '--depths',
            );
            break;
        case '--iters':
            iterations = parsePositiveInteger(process.argv[++i], '--iters');
            break;
        case '--warmup':
            warmup = parsePositiveInteger(process.argv[++i], '--warmup');
            break;
        case '--emit-dir':
            emitDir = process.argv[++i] ?? fail('--emit-dir requires a path');
            break;
        case '--output':
            outputPath = process.argv[++i] ?? fail('--output requires a path');
            break;
        case '--cpu':
            cpu = parseNonnegativeInteger(process.argv[++i], '--cpu');
            break;
        case '--perf-stat':
            perfStat = true;
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default:
            fail(`unknown option: ${arg}`);
    }
}

function requireExecutable(filePath, label) {
    if (!fs.existsSync(filePath)) fail(`${label} not found at ${filePath}`);
    try {
        fs.accessSync(filePath, fs.constants.X_OK);
    } catch {
        fail(`${label} is not executable at ${filePath}`);
    }
}

function findCommand(name) {
    for (const directory of (process.env.PATH ?? '').split(path.delimiter)) {
        if (directory === '') continue;
        const candidate = path.join(directory, name);
        try {
            fs.accessSync(candidate, fs.constants.X_OK);
            return candidate;
        } catch {
            // Keep looking.
        }
    }
    fail(`required command not found in PATH: ${name}`);
}

requireExecutable(zjsBin, 'zjs');
if (qjsBin !== null) requireExecutable(qjsBin, 'qjs');
const tasksetBin = cpu === null ? null : findCommand('taskset');
const perfBin = perfStat ? findCommand('perf') : null;
const objcopyBin = findCommand('objcopy');

function sha256(filePath) {
    return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function sourceFor(captureCount, useCount, depth, variant) {
    const declarations = [];
    for (let i = 0; i < captureCount; i += 1) {
        const name = `binding${String(i).padStart(4, '0')}`;
        declarations.push(`let ${name}=${i + 1};`);
    }

    const lines = ['function closureTopologyProbe(){'];
    if (variant === 'capture') lines.push(...declarations);
    for (let i = 0; i < depth; i += 1) {
        lines.push(`return function layer${String(i).padStart(4, '0')}(){`);
    }
    if (variant === 'local') lines.push(...declarations);
    lines.push('let total=0;');
    for (let use = 0; use < useCount; use += 1) {
        for (let i = 0; i < captureCount; i += 1) {
            lines.push(`total+=binding${String(i).padStart(4, '0')};`);
        }
    }
    lines.push('return total;');
    for (let i = 0; i < depth; i += 1) lines.push('};');
    lines.push('}', 'print(typeof closureTopologyProbe);', '');
    return lines.join('\n');
}

function parsePerfCounters(text) {
    const counters = {
        instructions: null,
        cycles: null,
    };
    for (const line of text.split('\n')) {
        const fields = line.split('\t');
        if (fields.length < 3 || fields[0] === '<not counted>' || fields[0] === '<not supported>') continue;
        const value = Number.parseInt(fields[0], 10);
        if (!Number.isSafeInteger(value)) continue;
        const event = fields[2];
        if (event === 'instructions' || event.includes('/instructions/')) counters.instructions = value;
        if (event === 'cycles' || event.includes('/cycles/')) counters.cycles = value;
    }
    if (counters.instructions === null || counters.cycles === null) {
        fail(`could not parse perf counters:\n${text}`);
    }
    return counters;
}

function run(binary, scriptPath, collectCounters) {
    let command = [binary, scriptPath];
    if (collectCounters) {
        command = [
            perfBin,
            'stat',
            '--no-big-num',
            '-x',
            '\t',
            '-e',
            'instructions,cycles',
            '--log-fd',
            '3',
            '--',
            ...command,
        ];
    }
    if (cpu !== null) command = [tasksetBin, '-c', String(cpu), ...command];

    const start = process.hrtime.bigint();
    const child = spawnSync(command[0], command.slice(1), {
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
        stdio: collectCounters
            ? ['ignore', 'pipe', 'pipe', 'pipe']
            : ['ignore', 'pipe', 'pipe'],
    });
    const elapsedNs = Number(process.hrtime.bigint() - start);
    if (child.error) fail(`${command[0]}: ${child.error.message}`);
    if (child.status !== 0) {
        fail(`${command.join(' ')} exited ${child.status}\nstdout:\n${child.stdout}\nstderr:\n${child.stderr}`);
    }
    if (child.stdout !== 'function\n' || child.stderr !== '') {
        fail(`${binary} oracle mismatch\nstdout: ${JSON.stringify(child.stdout)}\nstderr: ${JSON.stringify(child.stderr)}`);
    }
    return {
        elapsedNs,
        counters: collectCounters ? parsePerfCounters(child.output[3]) : null,
    };
}

function median(values) {
    const ordered = [...values].sort((a, b) => a - b);
    const middle = Math.floor(ordered.length / 2);
    return ordered.length % 2 === 1
        ? ordered[middle]
        : (ordered[middle - 1] + ordered[middle]) / 2;
}

function commandOutput(command, args, cwd = root) {
    const child = spawnSync(command, args, {
        cwd,
        encoding: 'utf8',
        maxBuffer: 16 * 1024 * 1024,
    });
    if (child.status !== 0) return null;
    return child.stdout.trim();
}

function processAffinity() {
    try {
        const status = fs.readFileSync('/proc/self/status', 'utf8');
        return status.match(/^Cpus_allowed_list:\s*(.+)$/m)?.[1] ?? null;
    } catch {
        return null;
    }
}

function pmuDevices() {
    try {
        return fs.readdirSync('/sys/bus/event_source/devices')
            .filter((name) => name.includes('pmu') || name.includes('cpu'))
            .sort();
    } catch {
        return [];
    }
}

function selectedCpuMidr() {
    if (cpu === null) return null;
    try {
        return fs.readFileSync(
            `/sys/devices/system/cpu/cpu${cpu}/regs/identification/midr_el1`,
            'utf8',
        ).trim();
    } catch {
        return null;
    }
}

function freezeBinary(name, sourceBinary, directory) {
    const source = path.resolve(sourceBinary);
    const frozen = path.join(directory, `frozen-${name}`);
    fs.copyFileSync(source, frozen);
    fs.chmodSync(frozen, 0o755);

    const textPath = path.join(directory, `frozen-${name}.text`);
    const objcopyOutput = path.join(directory, `frozen-${name}.objcopy`);
    const dumped = spawnSync(objcopyBin, [
        '--dump-section',
        `.text=${textPath}`,
        frozen,
        objcopyOutput,
    ], {
        encoding: 'utf8',
    });
    if (dumped.status !== 0) {
        fail(`objcopy could not extract .text from ${source}\n${dumped.stderr}`);
    }
    const metadata = {
        name,
        sourceBinary: source,
        frozenBinary: frozen,
        sha256: sha256(frozen),
        textSha256: sha256(textPath),
        bytes: fs.statSync(frozen).size,
        textBytes: fs.statSync(textPath).size,
    };
    fs.rmSync(textPath);
    fs.rmSync(objcopyOutput);
    return metadata;
}

function emptySamples(engines) {
    return Object.fromEntries(engines.map((engine) => [engine.name, {
        elapsedNs: [],
        instructions: [],
        cycles: [],
    }]));
}

function summarizeSamples(samples, engines, collectCounters) {
    return Object.fromEntries(engines.map((engine) => {
        const values = samples[engine.name];
        return [engine.name, {
            elapsedNs: median(values.elapsedNs),
            instructions: collectCounters ? median(values.instructions) : null,
            cycles: collectCounters ? median(values.cycles) : null,
        }];
    }));
}

function ratios(numerator, denominator) {
    return {
        elapsedNs: numerator.elapsedNs / denominator.elapsedNs,
        instructions: numerator.instructions === null ? null : numerator.instructions / denominator.instructions,
        cycles: numerator.cycles === null ? null : numerator.cycles / denominator.cycles,
    };
}

function differences(left, right) {
    return {
        elapsedNs: left.elapsedNs - right.elapsedNs,
        instructions: left.instructions === null ? null : left.instructions - right.instructions,
        cycles: left.cycles === null ? null : left.cycles - right.cycles,
    };
}

const generatedDir = emitDir === null
    ? fs.mkdtempSync(path.join(os.tmpdir(), 'zjs-resolve-closure-'))
    : path.resolve(emitDir);
const removeGeneratedDir = emitDir === null;
fs.mkdirSync(generatedDir, { recursive: true });

try {
    const engines = [freezeBinary('zjs', zjsBin, generatedDir)];
    if (qjsBin !== null) engines.push(freezeBinary('qjs', qjsBin, generatedDir));

    const results = [];
    for (const captureCount of captureCounts) {
        for (const useCount of usesPerCapture) {
            for (const depth of depths) {
                const scripts = {};
                for (const variant of ['capture', 'local']) {
                    const source = sourceFor(captureCount, useCount, depth, variant);
                    const scriptPath = path.join(
                        generatedDir,
                        `${variant}-c${captureCount}-u${useCount}-d${depth}.js`,
                    );
                    fs.writeFileSync(scriptPath, source);
                    scripts[variant] = {
                        path: scriptPath,
                        bytes: Buffer.byteLength(source),
                        sha256: crypto.createHash('sha256').update(source).digest('hex'),
                    };
                }
                if (scripts.capture.bytes !== scripts.local.bytes) {
                    fail('capture/local controls must have identical source byte counts');
                }

                const runners = [];
                for (const variant of ['capture', 'local']) {
                    for (const engine of engines) runners.push({ variant, engine });
                }
                for (let i = 0; i < warmup; i += 1) {
                    const order = i % 2 === 0 ? runners : [...runners].reverse();
                    for (const runner of order) {
                        run(runner.engine.frozenBinary, scripts[runner.variant].path, false);
                    }
                }

                const samples = {
                    capture: emptySamples(engines),
                    local: emptySamples(engines),
                };
                for (let i = 0; i < iterations; i += 1) {
                    const offset = i % runners.length;
                    const order = [...runners.slice(offset), ...runners.slice(0, offset)];
                    for (const runner of order) {
                        const sample = run(
                            runner.engine.frozenBinary,
                            scripts[runner.variant].path,
                            perfStat,
                        );
                        const target = samples[runner.variant][runner.engine.name];
                        target.elapsedNs.push(sample.elapsedNs);
                        if (sample.counters !== null) {
                            target.instructions.push(sample.counters.instructions);
                            target.cycles.push(sample.counters.cycles);
                        }
                    }
                }

                const medians = {
                    capture: summarizeSamples(samples.capture, engines, perfStat),
                    local: summarizeSamples(samples.local, engines, perfStat),
                };
                const captureOverLocal = Object.fromEntries(
                    engines.map((engine) => [
                        engine.name,
                        ratios(medians.capture[engine.name], medians.local[engine.name]),
                    ]),
                );
                const captureMinusLocal = Object.fromEntries(
                    engines.map((engine) => [
                        engine.name,
                        differences(medians.capture[engine.name], medians.local[engine.name]),
                    ]),
                );
                const zjsOverQjs = qjsBin === null
                    ? null
                    : {
                        capture: ratios(medians.capture.zjs, medians.capture.qjs),
                        local: ratios(medians.local.zjs, medians.local.qjs),
                    };

                results.push({
                    captureCount,
                    usesPerCapture: useCount,
                    depth,
                    referenceCount: captureCount * useCount,
                    sourceBytes: scripts.capture.bytes,
                    scripts,
                    samples,
                    medians,
                    captureOverLocal,
                    captureMinusLocal,
                    zjsOverQjs,
                });
            }
        }
    }

    const cpus = os.cpus();
    const report = {
        schema: 1,
        generatedAt: new Date().toISOString(),
        command: process.argv,
        dimensions: {
            captureCounts,
            usesPerCapture,
            depths,
        },
        iterations,
        warmup,
        cpu,
        perfStat,
        wallTimeIncludesToolWrappers: cpu !== null || perfStat,
        environment: {
            platform: process.platform,
            architecture: process.arch,
            release: os.release(),
            hostname: os.hostname(),
            cpuModel: cpus[0]?.model ?? null,
            logicalCpuCount: cpus.length,
            processAffinity: processAffinity(),
            selectedCpuMidr: selectedCpuMidr(),
            loadAverage: os.loadavg(),
            pmuDevices: pmuDevices(),
        },
        repository: {
            root,
            commit: commandOutput('git', ['rev-parse', 'HEAD']),
            dirty: commandOutput('git', ['status', '--porcelain=v1']) !== '',
        },
        oracle: {
            exitCode: 0,
            stdout: 'function\n',
            stderr: '',
        },
        control: {
            invariant: 'same source bytes, nesting, declarations, and references',
            changedMechanism: 'binding declaration is outer capture or deepest-function local',
            generatedFunctionsExecuted: false,
        },
        frozenBinariesRetained: !removeGeneratedDir,
        engines,
        results,
    };
    const json = `${JSON.stringify(report, null, 2)}\n`;
    process.stdout.write(json);
    if (outputPath !== null) {
        fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
        fs.writeFileSync(outputPath, json);
    }
} finally {
    if (removeGeneratedDir) fs.rmSync(generatedDir, { recursive: true, force: true });
}
