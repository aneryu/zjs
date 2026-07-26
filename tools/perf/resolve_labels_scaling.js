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
let sizes = [128, 256, 512, 1024];
let iterations = 9;
let warmup = 3;
let emitDir = null;
let outputPath = null;
let cpu = null;
let perfStat = false;

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1])} [options]

Generate branch-topology-dense JavaScript functions and measure whole-process
compile/startup cost. The generated function is never called, so execution cost
stays constant while resolve_labels input size and target-query count scale.

Options:
  --zjs PATH       zjs binary (default: ${zjsBin})
  --qjs PATH       optional QuickJS comparator
  --sizes LIST     comma-separated branch counts (default: ${sizes.join(',')})
  --iters N        timed paired iterations per size (default: ${iterations})
  --warmup N       warmup paired iterations per size (default: ${warmup})
  --emit-dir PATH  retain generated scripts in PATH instead of a temp directory
  --output PATH    write JSON to PATH as well as stdout
  --cpu N          pin every measured process to logical CPU N
  --perf-stat      record instructions and cycles for every timed sample
  -h, --help       show this help
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

for (let i = 2; i < process.argv.length; i += 1) {
    const arg = process.argv[i];
    switch (arg) {
        case '--zjs':
            zjsBin = process.argv[++i] ?? fail('--zjs requires a path');
            break;
        case '--qjs':
            qjsBin = process.argv[++i] ?? fail('--qjs requires a path');
            break;
        case '--sizes': {
            const raw = process.argv[++i] ?? fail('--sizes requires a list');
            sizes = raw.split(',').map((value) => parsePositiveInteger(value, '--sizes'));
            break;
        }
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

function sourceFor(branchCount) {
    const lines = [
        'function targetTopologyProbe(input) {',
        '    let value = 0;',
    ];
    for (let i = 0; i < branchCount; i += 1) {
        lines.push(`    if (input === ${i}) { value += ${i + 1}; } else { value -= ${i + 1}; }`);
    }
    lines.push(
        '    return value;',
        '}',
        'print(typeof targetTopologyProbe);',
        '',
    );
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

const generatedDir = emitDir === null
    ? fs.mkdtempSync(path.join(os.tmpdir(), 'zjs-resolve-labels-'))
    : path.resolve(emitDir);
const removeGeneratedDir = emitDir === null;
fs.mkdirSync(generatedDir, { recursive: true });

try {
    const scripts = sizes.map((size) => {
        const source = sourceFor(size);
        const scriptPath = path.join(generatedDir, `branches-${size}.js`);
        fs.writeFileSync(scriptPath, source);
        return {
            size,
            scriptPath,
            sourceBytes: Buffer.byteLength(source),
            sourceSha256: crypto.createHash('sha256').update(source).digest('hex'),
        };
    });

    const engines = [
        freezeBinary('zjs', zjsBin, generatedDir),
    ];
    if (qjsBin !== null) engines.push(freezeBinary('qjs', qjsBin, generatedDir));

    const results = [];
    for (const script of scripts) {
        for (let i = 0; i < warmup; i += 1) {
            const order = i % 2 === 0 ? engines : [...engines].reverse();
            for (const engine of order) run(engine.frozenBinary, script.scriptPath, false);
        }

        const samplesNs = Object.fromEntries(engines.map((engine) => [engine.name, []]));
        const samplesCounters = perfStat
            ? Object.fromEntries(engines.map((engine) => [engine.name, {
                instructions: [],
                cycles: [],
            }]))
            : null;
        for (let i = 0; i < iterations; i += 1) {
            const order = i % 2 === 0 ? engines : [...engines].reverse();
            for (const engine of order) {
                const sample = run(engine.frozenBinary, script.scriptPath, perfStat);
                samplesNs[engine.name].push(sample.elapsedNs);
                if (samplesCounters !== null) {
                    samplesCounters[engine.name].instructions.push(sample.counters.instructions);
                    samplesCounters[engine.name].cycles.push(sample.counters.cycles);
                }
            }
        }

        const mediansNs = Object.fromEntries(
            engines.map((engine) => [engine.name, median(samplesNs[engine.name])]),
        );
        const mediansCounters = samplesCounters === null
            ? null
            : Object.fromEntries(engines.map((engine) => [engine.name, {
                instructions: median(samplesCounters[engine.name].instructions),
                cycles: median(samplesCounters[engine.name].cycles),
            }]));
        results.push({
            branchCount: script.size,
            sourceBytes: script.sourceBytes,
            sourceSha256: script.sourceSha256,
            samplesNs,
            samplesCounters,
            mediansNs,
            mediansCounters,
            zjsOverQjs: qjsBin === null ? null : mediansNs.zjs / mediansNs.qjs,
            zjsOverQjsCounters: qjsBin === null || mediansCounters === null
                ? null
                : {
                    instructions: mediansCounters.zjs.instructions / mediansCounters.qjs.instructions,
                    cycles: mediansCounters.zjs.cycles / mediansCounters.qjs.cycles,
                },
        });
    }

    const cpus = os.cpus();
    const report = {
        schema: 1,
        generatedAt: new Date().toISOString(),
        command: process.argv,
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
