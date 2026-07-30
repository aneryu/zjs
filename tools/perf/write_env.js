#!/usr/bin/env node

const fs = require('node:fs');
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');
const process = require('node:process');
const { spawnSync } = require('node:child_process');

let outputPath = 'reports/perf/baseline/env-zjs-self.md';
let iters = process.env.BENCH_ITERS || '30';
let warmup = process.env.BENCH_WARMUP || '5';
let qjs = process.env.QJS || '';
let zjs = process.env.QJS_ZIG || 'zig-out/bin/zjs';
let notes = '';
let pinnedCpu = null;
let zjsBuildMode = process.env.ZJS_BUILD_MODE || '';
let zjsRepresentation = process.env.ZJS_JSVALUE_REPRESENTATION || '';

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'write_env.js')} [options]

Writes a benchmark environment note.

Options:
  --output PATH     Output markdown path (default: ${outputPath})
  --iters N         Benchmark timed iterations (default: ${iters})
  --warmup N        Benchmark warmup iterations (default: ${warmup})
  --qjs PATH        Optional external C QuickJS path
  --zjs PATH        zjs path (default: ${zjs})
  --cpu N           CPU used for pinned benchmark runs
  --zjs-build-mode MODE
                     Explicit zjs build mode metadata
  --zjs-jsvalue-representation NAME
                     Explicit zjs JSValue representation metadata
  --notes TEXT      Extra environment note
  -h, --help        Show this help`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function commandOutput(command, args, { allowNonZero = false, cwd = undefined } = {}) {
    const result = spawnSync(command, args, { encoding: 'utf8', cwd });
    if (result.error || (!allowNonZero && result.status !== 0)) return null;
    return result.stdout.trim();
}

function firstLine(text) {
    if (!text) return null;
    return text.split('\n')[0] || null;
}

function sha256File(filePath) {
    try {
        return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
    } catch {
        return null;
    }
}

function realpathOrResolved(filePath) {
    const resolved = path.resolve(filePath);
    try {
        return fs.realpathSync(resolved);
    } catch {
        return resolved;
    }
}

function gitRootFor(filePath) {
    return commandOutput('git', ['-C', path.dirname(realpathOrResolved(filePath)), 'rev-parse', '--show-toplevel']);
}

function gitIdentityFor(filePath) {
    const repository = gitRootFor(filePath);
    if (!repository) {
        return {
            repository: null,
            commit: null,
            dirty: null,
            unavailableReason: `git could not determine a repository containing ${realpathOrResolved(filePath)}`,
        };
    }
    const commit = commandOutput('git', ['-C', repository, 'rev-parse', 'HEAD']);
    const status = commandOutput('git', ['-C', repository, 'status', '--porcelain']);
    return {
        repository,
        commit,
        dirty: status == null ? null : status.length !== 0,
        unavailableReason:
            commit == null || status == null ? `git identity probe failed for ${repository}` : null,
    };
}

function cpuIdentity() {
    const lscpu = commandOutput('lscpu', []);
    if (lscpu) {
        const models = [...new Set(
            lscpu
                .split(/\r?\n/)
                .map((line) => line.match(/^\s*Model name:\s*(.+?)\s*$/)?.[1])
                .filter((value) => value && value.toLowerCase() !== 'unknown' && value !== '-'),
        )];
        if (models.length !== 0) return { model: models.join(' / '), source: 'lscpu Model name', raw: null };
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
            raw: null,
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
        return {
            model:
                `ARM implementer ${implementers.join('/') || 'unknown'}, ` +
                `parts ${parts.join('/') || 'unknown'}`,
            source: '/proc/cpuinfo implementer/part',
            raw: null,
        };
    }
    return {
        model: 'unknown',
        source: 'lscpu and /proc/cpuinfo',
        raw: [...new Set(identityLines)].join('; ') || lscpu || 'no CPU identity output',
    };
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
        case '--cpu': {
            const value = args[++i];
            if (value == null) fail('error: --cpu requires a value');
            const parsed = Number(value);
            if (!Number.isInteger(parsed) || parsed < 0) fail('error: --cpu must be a non-negative integer');
            pinnedCpu = parsed;
            break;
        }
        case '--zjs-build-mode':
            zjsBuildMode = args[++i] || fail('error: --zjs-build-mode requires a value');
            break;
        case '--zjs-jsvalue-representation':
            zjsRepresentation = args[++i] || fail('error: --zjs-jsvalue-representation requires a value');
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

const root = path.resolve(__dirname, '../..');
const cpu = os.cpus()[0] || { speed: 0 };
const identity = cpuIdentity();
const zigVersion = firstLine(commandOutput('zig', ['version'])) || 'unknown';
const ccVersion = firstLine(commandOutput('cc', ['--version'])) || 'unknown';
const bunVersion = firstLine(commandOutput('bun', ['--version'])) || 'unavailable';
const nodeVersion = process.version;
const kernel = firstLine(commandOutput('uname', ['-r'])) || os.release();
const uname = firstLine(commandOutput('uname', ['-a'])) || `${os.type()} ${os.release()} ${os.arch()}`;
const resolvedZjs = realpathOrResolved(zjs);
const resolvedQjs = qjs ? realpathOrResolved(qjs) : null;
const zjsIdentity = gitIdentityFor(resolvedZjs);
const qjsIdentity = resolvedQjs ? gitIdentityFor(resolvedQjs) : null;
const toolIdentity = gitIdentityFor(path.join(root, 'tools', 'perf', 'write_env.js'));
const qjsRepo = qjsIdentity?.repository ?? null;
const qjsHelpVersion = resolvedQjs
    ? firstLine(commandOutput(resolvedQjs, ['--help'], { allowNonZero: true })) || 'unavailable'
    : 'not configured';
let qjsFileVersion = 'not configured';
if (qjsRepo) {
    try {
        qjsFileVersion = fs.readFileSync(path.join(qjsRepo, 'VERSION'), 'utf8').trim();
    } catch {
        qjsFileVersion = 'unavailable';
    }
}
const versionCrossCheck = qjsFileVersion !== 'not configured' && qjsFileVersion !== 'unavailable'
    ? qjsHelpVersion.includes(qjsFileVersion)
    : 'unavailable';
const zjsSha256 = sha256File(resolvedZjs) || 'unavailable';
const qjsSha256 = resolvedQjs ? sha256File(resolvedQjs) || 'unavailable' : 'not configured';
const zjsCommit = zjsIdentity.commit || 'unavailable';
const zjsDirty = zjsIdentity.dirty == null ? 'unavailable' : String(zjsIdentity.dirty);
const qjsCommit = qjsIdentity?.commit || (qjs ? 'unavailable' : 'not configured');
const qjsDirty = qjsIdentity == null
    ? 'not configured'
    : qjsIdentity.dirty == null
      ? 'unavailable'
      : String(qjsIdentity.dirty);
const toolCommit = toolIdentity.commit || 'unavailable';
const toolDirty = toolIdentity.dirty == null ? 'unavailable' : String(toolIdentity.dirty);

const body = `# zjs performance environment

- Generated: ${new Date().toISOString()}
- Zig version: ${zigVersion}
- C compiler: ${ccVersion}
- Bun version: ${bunVersion}
- Node version: ${nodeVersion}
- OS: ${uname}
- Kernel: ${kernel}
- Architecture: ${os.arch()}
- CPU: ${identity.model}
- CPU model source: ${identity.source}
${identity.raw ? `- CPU probe raw: ${identity.raw}\n` : ''}- Pinned CPU: ${pinnedCpu == null ? 'unavailable (--cpu not provided)' : pinnedCpu}
- Logical CPUs: ${os.cpus().length}
- CPU reported MHz: ${cpu.speed}
- tool repository: ${toolIdentity.repository || 'unavailable'}
- tool repository commit: ${toolCommit}
- tool repository dirty: ${toolDirty}
- zjs repository: ${zjsIdentity.repository || 'unavailable'}
- zjs repository commit: ${zjsCommit}
- zjs repository dirty: ${zjsDirty}
- zjs binary: \`${resolvedZjs}\`
- zjs binary SHA-256: ${zjsSha256}
- zjs build mode: ${zjsBuildMode || 'unavailable (binary does not export it; pass --zjs-build-mode or ZJS_BUILD_MODE)'}
- zjs JSValue representation: ${zjsRepresentation || 'unavailable (binary does not export it; pass --zjs-jsvalue-representation or ZJS_JSVALUE_REPRESENTATION)'}
- zjs provenance note: repository state is inferred from the binary realpath; SHA-256 is the authoritative binary identity
- QuickJS repository: ${qjsIdentity?.repository || (qjs ? 'unavailable' : 'not configured')}
- QuickJS repository commit: ${qjsCommit}
- QuickJS repository dirty: ${qjsDirty}
- QuickJS VERSION: ${qjsFileVersion}
- QuickJS binary: \`${resolvedQjs || 'not configured'}\`
- QuickJS binary SHA-256: ${qjsSha256}
- qjs help/version probe: ${qjsHelpVersion}
- qjs VERSION/help cross-check: ${versionCrossCheck}
- Benchmark iters: ${iters}
- Benchmark warmup: ${warmup}
- CPU frequency scaling: not controlled by this script
- CPU affinity: ${pinnedCpu == null ? 'unavailable (--cpu not provided)' : `taskset -c ${pinnedCpu}`}
${zjsIdentity.unavailableReason ? `- zjs git identity warning: ${zjsIdentity.unavailableReason}\n` : ''}${qjsIdentity?.unavailableReason ? `- QuickJS git identity warning: ${qjsIdentity.unavailableReason}\n` : ''}${toolIdentity.unavailableReason ? `- tool git identity warning: ${toolIdentity.unavailableReason}\n` : ''}
${notes ? `- Notes: ${notes}\n` : ''}
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, body);
