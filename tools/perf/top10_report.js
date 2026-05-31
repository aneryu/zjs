#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

let outputPath = null;
let sortBy = 'ratio';

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'top10_report.js')} [options] REPORT_JSON

Writes a markdown summary of the slowest microbench cases.

Options:
  --output PATH       Write markdown to PATH
  --sort ratio|zjs    Sort by zjs/qjs ratio or zjs avg ms (default: ${sortBy})
  -h, --help          Show this help`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function readReport(filePath) {
    let report;
    try {
        report = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (err) {
        fail(`error: unable to read report ${filePath}: ${err.message}`);
    }
    if (!report || !Array.isArray(report.cases)) fail(`error: ${filePath} is not a microbench JSON report`);
    return report;
}

function fmt(value, digits = 3) {
    return Number.isFinite(value) ? value.toFixed(digits) : '-';
}

function rowFor(item, index) {
    return `| ${index + 1} | \`${item.name}\` | ${item.category || ''} | ${fmt(item.qjs?.avg)} | ${fmt(item.zjs?.avg)} | ${fmt(item.ratio, 2)} | ${item.winner || ''} |`;
}

const positional = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--output':
            outputPath = args[++i] || fail('error: --output requires a path');
            break;
        case '--sort':
            sortBy = args[++i] || fail('error: --sort requires a value');
            if (sortBy !== 'ratio' && sortBy !== 'zjs') fail('error: --sort must be ratio or zjs');
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

if (positional.length !== 1) {
    usage();
    process.exit(2);
}

const reportPath = positional[0];
const report = readReport(reportPath);
const compatible = report.cases.filter((item) => item.status === 'ok');
compatible.sort((a, b) => {
    const lhs = sortBy === 'zjs' ? a.zjs?.avg : a.ratio;
    const rhs = sortBy === 'zjs' ? b.zjs?.avg : b.ratio;
    return (Number.isFinite(rhs) ? rhs : -Infinity) - (Number.isFinite(lhs) ? lhs : -Infinity);
});

const top = compatible.slice(0, 10);
const lines = [
    '# zjs microbench top 10',
    '',
    `- Source report: \`${reportPath}\``,
    `- Generated: ${new Date().toISOString()}`,
    `- Sort: ${sortBy === 'zjs' ? 'zjs avg ms' : 'zjs/qjs ratio'}`,
    `- Compatible cases: ${report.summary?.compatible ?? compatible.length}`,
    `- Unsupported cases: ${report.summary?.unsupported ?? '-'}`,
    `- Skipped cases: ${report.summary?.skipped ?? '-'}`,
    `- Geometric mean: ${fmt(report.summary?.geometricMean, 4)}`,
    '',
    '| Rank | Case | Category | qjs avg ms | zjs avg ms | zjs/qjs | Winner |',
    '|---:|---|---|---:|---:|---:|---|',
    ...top.map(rowFor),
    '',
];

const markdown = `${lines.join('\n')}`;
if (outputPath) {
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, markdown);
} else {
    process.stdout.write(markdown);
}
