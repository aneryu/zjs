#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const process = require('node:process');
const { spawnSync } = require('node:child_process');

let zjs = process.env.QJS_ZIG || 'zig-out/bin/zjs';
let outputPath = null;
let stdoutPath = null;
let expectStdout = null;
const opcodeMaxExpectations = [];

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'run_runtime_profile.js')} [options] SCRIPT [-- SCRIPT_ARGS...]

Runs zjs --perf-json with opcode instrumentation for one script and writes an
explicit runtime-profile artifact. This is intentionally separate from
zjs-microbench reports.

Options:
  --zjs PATH              zjs executable (default: ${zjs})
  --output PATH           Write runtime profile JSON to PATH
  --stdout PATH           Write script stdout to PATH instead of embedding it
  --expect-stdout TEXT    Require exact script stdout
  --expect-opcode-max NAME=COUNT
                          Require opcode NAME to execute at most COUNT times
  -h, --help              Show this help`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function writeFile(filePath, data) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, data);
}

function parseOpcodeMax(value) {
    if (value == null) fail('error: --expect-opcode-max requires NAME=COUNT');
    const separator = value.indexOf('=');
    if (separator <= 0 || separator === value.length - 1) fail('error: --expect-opcode-max requires NAME=COUNT');
    const name = value.slice(0, separator);
    const max = Number(value.slice(separator + 1));
    if (!Number.isInteger(max) || max < 0) fail('error: --expect-opcode-max COUNT must be a non-negative integer');
    return { name, max };
}

function opcodeCount(profile, name) {
    const rows = profile?.opcode_profile?.opcodes;
    if (!Array.isArray(rows)) return null;
    const row = rows.find((entry) => entry && entry.name === name);
    if (row == null) return 0;
    return Number.isFinite(row.count) ? row.count : null;
}

const positional = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--zjs':
            zjs = args[++i] || fail('error: --zjs requires a path');
            break;
        case '--output':
            outputPath = args[++i] || fail('error: --output requires a path');
            break;
        case '--stdout':
            stdoutPath = args[++i] || fail('error: --stdout requires a path');
            break;
        case '--expect-stdout':
            expectStdout = args[++i] ?? fail('error: --expect-stdout requires text');
            break;
        case '--expect-opcode-max':
            opcodeMaxExpectations.push(parseOpcodeMax(args[++i]));
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        case '--':
            positional.push(...args.slice(i + 1));
            i = args.length;
            break;
        default:
            if (arg.startsWith('-')) fail(`error: unknown option: ${arg}`);
            positional.push(arg);
    }
}

if (positional.length < 1) {
    usage();
    process.exit(2);
}

const script = positional[0];
const scriptArgs = positional.slice(1);
const commandArgs = ['--perf-json', '--profile-opcodes', script, ...scriptArgs];
const result = spawnSync(zjs, commandArgs, {
    encoding: 'utf8',
    maxBuffer: 128 * 1024 * 1024,
});

if (result.error) fail(`error: failed to run ${zjs}: ${result.error.message}`, 1);
if (result.status !== 0) {
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    fail(`error: ${zjs} exited with status ${result.status}`, result.status || 1);
}
const profileMarker = '\nZJS opcode profile\n';
const markerIndex = result.stdout.lastIndexOf(profileMarker);
if (markerIndex < 0) fail('error: zjs --profile-opcodes output marker was not found on stdout', 1);
const scriptStdout = result.stdout.slice(0, markerIndex);

if (expectStdout != null && scriptStdout !== expectStdout) {
    fail(`error: script stdout mismatch: expected ${JSON.stringify(expectStdout)}, got ${JSON.stringify(scriptStdout)}`, 1);
}

let profile;
try {
    profile = JSON.parse(result.stderr);
} catch (err) {
    fail(`error: ${zjs} did not emit valid --perf-json on stderr: ${err.message}`, 1);
}
if (!profile || typeof profile.file !== 'string' || !Number.isFinite(profile.total_ns) || !profile.memory) {
    fail('error: zjs --perf-json output has an unexpected shape', 1);
}
if (!profile.opcode_profile || !Number.isFinite(profile.opcode_profile.opcodes_executed) || !Array.isArray(profile.opcode_profile.opcodes)) {
    fail('error: zjs --perf-json output is missing opcode_profile details', 1);
}
for (const expectation of opcodeMaxExpectations) {
    const count = opcodeCount(profile, expectation.name);
    if (count == null) fail(`error: opcode count for ${expectation.name} is missing or invalid`, 1);
    if (count > expectation.max) {
        fail(`error: opcode ${expectation.name} exceeded max ${expectation.max}: ${count}`, 1);
    }
}

if (stdoutPath) writeFile(stdoutPath, scriptStdout);
const artifact = {
    tool: 'zjs-runtime-profile',
    timestamp: new Date().toISOString(),
    zjs,
    script,
    scriptArgs,
    stdoutPath: stdoutPath || null,
    stdout: stdoutPath ? undefined : scriptStdout,
    profile,
};

const json = `${JSON.stringify(artifact, null, 2)}\n`;
if (outputPath) {
    writeFile(outputPath, json);
} else {
    process.stdout.write(json);
}
