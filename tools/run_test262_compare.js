#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const root = path.resolve(__dirname, '..');
const test262Dir = path.join(root, 'test262');
const cBin = path.resolve(root, '..', 'quickjs', 'build', 'run-test262');
const zigBin = path.join(root, 'zig-out', 'bin', 'zjs');
const cPassingListPath = '/tmp/test262_c_passing_list.json';

const defaultTestGlob = 'test/language/statements/**/*.js';

// Mode: 'full' runs all tests and saves C-passing list, 'compare' only tests C-passing cases (default)
// Use 'full' argument to run full mode. Any remaining arguments are test files or globs.
const cliArgs = process.argv.slice(2);
const requestedMode = cliArgs[0] === 'full' || cliArgs[0] === 'compare' ? cliArgs.shift() : null;
const mode = requestedMode ?? 'compare';
const hasExplicitTests = cliArgs.length > 0;
const testPatterns = hasExplicitTests ? cliArgs : [defaultTestGlob];

// Concurrency for parallel test execution
const CONCURRENCY = positiveIntegerEnv('TEST262_CONCURRENCY', 8);
const HARNESS_THREADS = positiveIntegerEnv('TEST262_HARNESS_THREADS', 1);
const TEST_TIMEOUT_MS = positiveIntegerEnv('TEST262_TIMEOUT_MS', 10000);
const PROCESS_TIMEOUT_MS = TEST_TIMEOUT_MS + 5000;

const defaultHostType = process.env.TEST262_HOST_TYPE;
const engines = {
    c: {
        label: 'C',
        hostType: process.env.TEST262_C_HOST_TYPE ?? defaultHostType ?? 'qjs',
        hostPath: process.env.TEST262_C_HOST_PATH ?? cBin,
    },
    zig: {
        label: 'Zig',
        hostType: process.env.TEST262_ZIG_HOST_TYPE ?? defaultHostType ?? 'hermes',
        hostPath: process.env.TEST262_ZIG_HOST_PATH ?? zigBin,
    },
};

function positiveIntegerEnv(name, fallback) {
    const value = Number.parseInt(process.env[name] ?? `${fallback}`, 10);
    return Number.isFinite(value) && value > 0 ? value : fallback;
}

function which(command) {
    const result = spawnSync('which', [command], { encoding: 'utf8' });
    if (result.status !== 0) return null;
    return result.stdout.trim().split('\n')[0] || null;
}

function resolveHarnessBin() {
    if (process.env.TEST262_HARNESS) return process.env.TEST262_HARNESS;

    const localHarness = path.join(test262Dir, 'node_modules', '.bin', 'test262-harness');
    if (fs.existsSync(localHarness)) return localHarness;

    const pathHarness = which('test262-harness');
    if (pathHarness) return pathHarness;

    console.error('Error: test262-harness not found. Install test262 dependencies or set TEST262_HARNESS.');
    process.exit(1);
}

const harnessBin = resolveHarnessBin();

function assertReadablePath(label, filePath) {
    if (!fs.existsSync(filePath)) {
        console.error(`Error: ${label} not found: ${filePath}`);
        process.exit(1);
    }
}

function toPosixPath(filePath) {
    return filePath.split(path.sep).join('/');
}

function toTest262Relative(input) {
    const normalized = input.replaceAll('\\', '/');
    if (normalized.startsWith('test262/')) {
        return normalized.slice('test262/'.length);
    }

    const absolute = path.isAbsolute(input) ? input : path.resolve(root, input);
    const relativeToTest262 = path.relative(test262Dir, absolute);
    if (!relativeToTest262.startsWith('..') && relativeToTest262 !== '') {
        return toPosixPath(relativeToTest262);
    }

    return normalized;
}

function escapeRegExp(char) {
    return char.replace(/[|\\{}()[\]^$+?.]/g, '\\$&');
}

function globToRegExp(glob) {
    let source = '^';
    for (let i = 0; i < glob.length; i++) {
        const char = glob[i];

        if (char === '*') {
            if (glob[i + 1] === '*') {
                const followedBySlash = glob[i + 2] === '/';
                source += followedBySlash ? '(?:.*/)?' : '.*';
                i += followedBySlash ? 2 : 1;
            } else {
                source += '[^/]*';
            }
        } else if (char === '?') {
            source += '[^/]';
        } else {
            source += escapeRegExp(char);
        }
    }
    source += '$';
    return new RegExp(source);
}

function listJsFiles(baseDir) {
    const files = [];
    if (!fs.existsSync(baseDir)) return files;

    for (const entry of fs.readdirSync(baseDir, { withFileTypes: true })) {
        const absolute = path.join(baseDir, entry.name);
        if (entry.isDirectory()) {
            files.push(...listJsFiles(absolute));
        } else if (entry.isFile() && entry.name.endsWith('.js')) {
            files.push(toPosixPath(path.relative(test262Dir, absolute)));
        }
    }

    return files;
}

function globBaseDir(pattern) {
    const parts = pattern.split('/');
    const baseParts = [];
    for (const part of parts) {
        if (part.includes('*') || part.includes('?')) break;
        baseParts.push(part);
    }
    return path.join(test262Dir, ...baseParts);
}

function expandPattern(pattern) {
    const relativePattern = toTest262Relative(pattern);
    const absolute = path.join(test262Dir, relativePattern);

    if (!relativePattern.includes('*') && !relativePattern.includes('?')) {
        if (!fs.existsSync(absolute)) {
            console.error(`Error: test path not found: ${pattern}`);
            process.exit(1);
        }

        const stat = fs.statSync(absolute);
        if (stat.isDirectory()) return listJsFiles(absolute);
        if (stat.isFile()) return [relativePattern];

        return [];
    }

    const matcher = globToRegExp(relativePattern);
    return listJsFiles(globBaseDir(relativePattern)).filter((file) => matcher.test(file));
}

function getTestFiles() {
    const files = new Set();
    for (const pattern of testPatterns) {
        for (const file of expandPattern(pattern)) {
            files.add(file);
        }
    }
    return Array.from(files).sort();
}

function runCommand(command, args, options) {
    return new Promise((resolve) => {
        const child = spawn(command, args, {
            cwd: options.cwd,
            stdio: ['ignore', 'pipe', 'pipe'],
        });

        let stdout = '';
        let stderr = '';
        let settled = false;
        const timer = setTimeout(() => {
            settled = true;
            child.kill('SIGKILL');
            resolve({
                exitCode: 124,
                signal: 'SIGKILL',
                stdout,
                stderr: `${stderr}\nTimed out after ${options.timeoutMs}ms`.trim(),
            });
        }, options.timeoutMs);

        child.stdout.on('data', (chunk) => {
            stdout += chunk.toString();
        });
        child.stderr.on('data', (chunk) => {
            stderr += chunk.toString();
        });
        child.on('error', (error) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve({ exitCode: 1, signal: null, stdout, stderr: error.message });
        });
        child.on('close', (code, signal) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            resolve({ exitCode: code ?? 1, signal, stdout, stderr });
        });
    });
}

function parseHarnessResult(commandResult) {
    let records;
    try {
        records = JSON.parse(commandResult.stdout);
    } catch {
        return {
            pass: false,
            exitCode: commandResult.exitCode,
            stdout: commandResult.stdout,
            stderr: commandResult.stderr,
            message: commandResult.stderr.trim() || 'Invalid test262-harness JSON output',
            scenarioCount: 0,
        };
    }

    if (!Array.isArray(records) || records.length === 0) {
        return {
            pass: false,
            exitCode: commandResult.exitCode,
            stdout: commandResult.stdout,
            stderr: commandResult.stderr,
            message: 'test262-harness returned no test records',
            scenarioCount: 0,
        };
    }

    const failures = records.filter((record) => !record.result?.pass);
    return {
        pass: commandResult.exitCode === 0 && failures.length === 0,
        exitCode: commandResult.exitCode,
        stdout: commandResult.stdout,
        stderr: commandResult.stderr,
        message: failures.map((record) => record.result?.message ?? 'failed').join('; '),
        scenarioCount: records.length,
    };
}

async function runHarnessTest(engine, testFile) {
    // Command shape:
    // test262-harness --host-type=<type> --host-path=<path> test/**/*.js
    // Each invocation receives one concrete test file; this script owns outer parallelism.
    // QuickJS C uses the qjs eshost agent with run-test262, because plain qjs does not support -N.
    const args = [
        `--host-type=${engine.hostType}`,
        `--host-path=${engine.hostPath}`,
        `--threads=${HARNESS_THREADS}`,
        `--timeout=${TEST_TIMEOUT_MS}`,
        '--reporter=json',
        '--reporter-keys=file,result',
        testFile,
    ];

    const commandResult = await runCommand(harnessBin, args, {
        cwd: test262Dir,
        timeoutMs: PROCESS_TIMEOUT_MS,
    });

    return parseHarnessResult(commandResult);
}

async function runTestsParallel(testFiles, engine) {
    const results = new Array(testFiles.length);
    let index = 0;
    const workerCount = Math.min(CONCURRENCY, testFiles.length);

    async function worker() {
        while (true) {
            const i = index++;
            if (i >= testFiles.length) break;
            const testFile = testFiles[i];
            const result = await runHarnessTest(engine, testFile);
            results[i] = result;
        }
    }

    const workers = [];
    for (let i = 0; i < workerCount; i++) {
        workers.push(worker());
    }

    await Promise.all(workers);
    return results;
}

async function main() {
    assertReadablePath('C engine binary', engines.c.hostPath);
    assertReadablePath('Zig engine binary', engines.zig.hostPath);

    let testFiles = getTestFiles();

    // Default compare mode filters to the saved C-passing set. Explicit file/glob arguments run as requested.
    if (mode === 'compare' && !hasExplicitTests) {
        if (!fs.existsSync(cPassingListPath)) {
            console.error('Error: C-passing list not found. Run with "full" argument first.');
            process.exit(1);
        }
        const cPassingList = JSON.parse(fs.readFileSync(cPassingListPath, 'utf8'));
        const cPassingSet = new Set(cPassingList);
        testFiles = testFiles.filter((file) => cPassingSet.has(file));
        console.log(`Testing ${testFiles.length} C-passing tests only`);
    } else {
        console.log(`Found ${testFiles.length} test files`);
    }

    if (testFiles.length === 0) {
        console.error('Error: no test files matched.');
        process.exit(1);
    }

    console.log(`Running one test262-harness process per file with ${CONCURRENCY} parallel workers...`);
    console.log(`C host: ${engines.c.hostType} ${engines.c.hostPath}`);
    console.log(`Zig host: ${engines.zig.hostType} ${engines.zig.hostPath}`);

    const cResults = await runTestsParallel(testFiles, engines.c);
    const zigResults = await runTestsParallel(testFiles, engines.zig);

    const cResultsFormatted = [];
    const zigResultsFormatted = [];

    for (let i = 0; i < testFiles.length; i++) {
        const relativePath = testFiles[i];
        const cResult = cResults[i];
        const zigResult = zigResults[i];

        const cPass = cResult.pass;
        const zigPass = zigResult.pass;

        cResultsFormatted.push({
            file: relativePath,
            pass: cPass,
            exitCode: cResult.exitCode,
            message: cResult.message,
            scenarioCount: cResult.scenarioCount,
        });
        zigResultsFormatted.push({
            file: relativePath,
            pass: zigPass,
            exitCode: zigResult.exitCode,
            message: zigResult.message,
            scenarioCount: zigResult.scenarioCount,
        });

        if (cPass && zigPass) {
            console.log(`✓ ${relativePath}`);
        } else if (cPass && !zigPass) {
            console.log(`C ONLY ${relativePath}`);
        } else if (!cPass && zigPass) {
            console.log(`ZIG ONLY ${relativePath}`);
        } else {
            console.log(`✗ ${relativePath}`);
        }
    }

    const cPassCount = cResultsFormatted.filter((r) => r.pass).length;
    const zigPassCount = zigResultsFormatted.filter((r) => r.pass).length;

    console.log('\n=== Summary ===');
    console.log(`C version: ${cPassCount}/${testFiles.length} passed`);
    console.log(`Zig version: ${zigPassCount}/${testFiles.length} passed`);

    const cByFile = new Map(cResultsFormatted.map((result) => [result.file, result]));
    const zigByFile = new Map(zigResultsFormatted.map((result) => [result.file, result]));
    const cOnly = cResultsFormatted.filter((r) => r.pass && !zigByFile.get(r.file)?.pass);
    const zigOnly = zigResultsFormatted.filter((r) => r.pass && !cByFile.get(r.file)?.pass);
    const bothPass = cResultsFormatted.filter((r) => r.pass && zigByFile.get(r.file)?.pass);

    console.log(`\nBoth pass: ${bothPass.length}`);
    console.log(`C only: ${cOnly.length}`);
    console.log(`Zig only: ${zigOnly.length}`);

    if (cOnly.length > 0) {
        console.log('\nC only passes:');
        cOnly.forEach((r) => console.log(`  ${r.file}`));
    }

    if (zigOnly.length > 0) {
        console.log('\nZig only passes:');
        zigOnly.forEach((r) => console.log(`  ${r.file}`));
    }

    // Save results
    fs.writeFileSync('/tmp/test262_c_results.json', JSON.stringify(cResultsFormatted, null, 2));
    fs.writeFileSync('/tmp/test262_zig_results.json', JSON.stringify(zigResultsFormatted, null, 2));

    // Save C-passing list in full mode
    if (mode === 'full' && !hasExplicitTests) {
        const cPassingList = cResultsFormatted.filter((r) => r.pass).map((r) => r.file);
        fs.writeFileSync(cPassingListPath, JSON.stringify(cPassingList, null, 2));
        console.log(`\nSaved ${cPassingList.length} C-passing tests to ${cPassingListPath}`);
    } else if (mode === 'full') {
        console.log('\nSkipped updating C-passing list because explicit test files/globs were provided.');
    }
}

main();
