#!/usr/bin/env node

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const process = require('node:process');
const { spawnSync } = require('node:child_process');

let outputPath = 'reports/perf/baseline/env.md';
let iters = process.env.BENCH_ITERS || '30';
let warmup = process.env.BENCH_WARMUP || '5';
let qjs = process.env.QJS || '';
let zjs = process.env.QJS_ZIG || 'zig-out/bin/zjs';
let notes = '';

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'write_env.js')} [options]

Writes a benchmark environment note for reports/perf/baseline/env.md.

Options:
  --output PATH     Output markdown path (default: ${outputPath})
  --iters N         Benchmark timed iterations (default: ${iters})
  --warmup N        Benchmark warmup iterations (default: ${warmup})
  --qjs PATH        Optional external C QuickJS path
  --zjs PATH        zjs path (default: ${zjs})
  --notes TEXT      Extra environment note
  -h, --help        Show this help`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function commandOutput(command, args) {
    const result = spawnSync(command, args, { encoding: 'utf8' });
    if (result.status !== 0) return null;
    return result.stdout.trim();
}

function firstLine(text) {
    if (!text) return null;
    return text.split('\n')[0] || null;
}

const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--output':
            outputPath = args[++i] || fail('error: --output requires a path');
            break;
        case '--iters':
            iters = args[++i] || fail('error: --iters requires a value');
            break;
        case '--warmup':
            warmup = args[++i] || fail('error: --warmup requires a value');
            break;
        case '--qjs':
            qjs = args[++i] || fail('error: --qjs requires a path');
            break;
        case '--zjs':
            zjs = args[++i] || fail('error: --zjs requires a path');
            break;
        case '--notes':
            notes = args[++i] || fail('error: --notes requires text');
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        default:
            fail(`error: unknown option: ${arg}`);
    }
}

const cpu = os.cpus()[0] || { model: 'unknown', speed: 0 };
const zigVersion = firstLine(commandOutput('zig', ['version'])) || 'unknown';
const uname = firstLine(commandOutput('uname', ['-a'])) || `${os.type()} ${os.release()} ${os.arch()}`;
const qjsVersion = qjs ? firstLine(commandOutput(qjs, ['--help'])) || 'unavailable' : 'not configured';

const body = `# zjs performance baseline environment

- Generated: ${new Date().toISOString()}
- Zig version: ${zigVersion}
- OS: ${uname}
- CPU: ${cpu.model}
- Logical CPUs: ${os.cpus().length}
- CPU reported MHz: ${cpu.speed}
- QJS: \`${qjs || 'not configured'}\`
- QJS_ZIG: \`${zjs}\`
- qjs help/version probe: ${qjsVersion}
- Benchmark iters: ${iters}
- Benchmark warmup: ${warmup}
- CPU frequency scaling: not controlled by this script
- CPU affinity: not controlled by this script
${notes ? `- Notes: ${notes}\n` : ''}
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, body);
