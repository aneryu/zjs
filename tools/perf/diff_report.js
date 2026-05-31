#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');

const defaultCaseRegressionRatio = 1.10;
const defaultCaseImprovementRatio = 0.90;
const defaultCaseAbsoluteMs = 0.05;
const defaultGeomeanRegressionRatio = 1.05;

let emitJson = false;
let failOnCaseRegression = true;
let failOnGeomeanRegression = true;
let enforceSameSampleConfig = true;
let caseRegressionRatio = defaultCaseRegressionRatio;
let caseImprovementRatio = defaultCaseImprovementRatio;
let caseAbsoluteMs = defaultCaseAbsoluteMs;
let geomeanRegressionRatio = defaultGeomeanRegressionRatio;
let geomeanImprovementRatio = null;
const namedCaseRegressions = new Map();
const requiredCaseImprovements = new Map();

function usage() {
    console.log(`Usage: ${path.basename(process.argv[1] || 'diff_report.js')} [options] OLD_REPORT NEW_REPORT

Compares two zjs microbench JSON reports.

Options:
  --json                         Print machine-readable JSON
  --case-regression-ratio N      Per-case regression ratio (default: ${defaultCaseRegressionRatio})
  --case-improvement-ratio N     Per-case improvement ratio (default: ${defaultCaseImprovementRatio})
  --case-absolute-ms N           Minimum absolute zjs avg delta in ms (default: ${defaultCaseAbsoluteMs})
  --case-regression CASE:RATIO[:MS]
                                 Per-case regression budget override
  --require-case-improvement CASE:RATIO
                                 Require one named case to improve by this ratio
  --geomean-regression-ratio N   Summary geomean regression ratio (default: ${defaultGeomeanRegressionRatio})
  --geomean-improvement-ratio N  Require summary geomean to improve by this ratio
  --warn-case-regressions        Report case regressions but do not fail on them
  --ignore-geomean-regression    Report geomean but do not fail on regression
  --allow-sample-config-drift    Allow comparing reports with different iters/warmup
  -h, --help                     Show this help`);
}

function fail(message, code = 2) {
    console.error(message);
    process.exit(code);
}

function parseNumberOption(value, label) {
    if (value == null) fail(`error: ${label} requires a value`);
    const parsed = Number(value);
    if (!Number.isFinite(parsed) || parsed <= 0) fail(`error: ${label} must be a positive number`);
    return parsed;
}

function parseNamedRatioSpec(value, label, allowAbsoluteMs) {
    if (value == null) fail(`error: ${label} requires CASE:RATIO${allowAbsoluteMs ? '[:MS]' : ''}`);
    const parts = value.split(':');
    if (parts.length < 2 || parts.length > (allowAbsoluteMs ? 3 : 2) || parts[0].length === 0) {
        fail(`error: ${label} expects CASE:RATIO${allowAbsoluteMs ? '[:MS]' : ''}`);
    }
    const ratio = parseNumberOption(parts[1], `${label} ratio`);
    const absoluteMs = parts.length === 3 ? parseNumberOption(parts[2], `${label} absolute ms`) : null;
    return { name: parts[0], ratio, absoluteMs };
}

function readReport(filePath, label) {
    let parsed;
    try {
        parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch (err) {
        fail(`error: unable to read ${label} report ${filePath}: ${err.message}`);
    }
    if (!parsed || !Array.isArray(parsed.cases)) {
        fail(`error: ${label} report ${filePath} is not a microbench JSON report`);
    }
    return parsed;
}

function countStatus(report, status) {
    return report.cases.filter((row) => row.status === status).length;
}

function summaryCount(report, status) {
    if (report.summary && Number.isFinite(report.summary[status])) return report.summary[status];
    return countStatus(report, status);
}

function reportGeomean(report) {
    const fromSummary = report.summary && report.summary.geometricMean;
    if (Number.isFinite(fromSummary)) return fromSummary;
    const ratios = report.cases
        .filter((row) => row.status === 'ok')
        .map((row) => row.ratio)
        .filter((ratio) => Number.isFinite(ratio) && ratio > 0);
    if (ratios.length === 0) return null;
    return Math.exp(ratios.reduce((sum, ratio) => sum + Math.log(ratio), 0) / ratios.length);
}

function caseMap(report) {
    const result = new Map();
    for (const row of report.cases) result.set(row.name, row);
    return result;
}

function percentDelta(oldValue, newValue) {
    if (!Number.isFinite(oldValue) || oldValue === 0 || !Number.isFinite(newValue)) return null;
    return ((newValue - oldValue) / oldValue) * 100;
}

function statusText(row) {
    if (!row) return 'missing';
    return row.status || 'unknown';
}

function sampleConfig(report) {
    const iters = report && report.iters;
    const warmup = report && report.warmup;
    if (!Number.isFinite(iters) || !Number.isFinite(warmup)) return null;
    return { iters, warmup };
}

function sameSampleConfig(oldReport, newReport) {
    const oldConfig = sampleConfig(oldReport);
    const newConfig = sampleConfig(newReport);
    if (oldConfig == null || newConfig == null) return false;
    return oldConfig.iters === newConfig.iters && oldConfig.warmup === newConfig.warmup;
}

function sampleConfigText(config) {
    if (config == null) return 'missing';
    return `iters=${config.iters}, warmup=${config.warmup}`;
}

function compareReports(oldReport, newReport) {
    const oldCases = caseMap(oldReport);
    const newCases = caseMap(newReport);
    const statusChanges = [];
    const regressions = [];
    const improvements = [];
    const warnings = [];
    const failures = [];

    const oldCompatible = summaryCount(oldReport, 'compatible');
    const newCompatible = summaryCount(newReport, 'compatible');
    const oldUnsupported = summaryCount(oldReport, 'unsupported');
    const newUnsupported = summaryCount(newReport, 'unsupported');
    const oldSkipped = summaryCount(oldReport, 'skipped');
    const newSkipped = summaryCount(newReport, 'skipped');
    const oldGeomean = reportGeomean(oldReport);
    const newGeomean = reportGeomean(newReport);
    const oldSampleConfig = sampleConfig(oldReport);
    const newSampleConfig = sampleConfig(newReport);

    if (enforceSameSampleConfig && !sameSampleConfig(oldReport, newReport)) {
        failures.push(
            `sample config changed: old ${sampleConfigText(oldSampleConfig)} -> new ${sampleConfigText(newSampleConfig)}`,
        );
    }

    if (newCompatible < oldCompatible) {
        failures.push(`compatible case count dropped: ${oldCompatible} -> ${newCompatible}`);
    }
    if (newUnsupported > oldUnsupported) {
        failures.push(`unsupported case count increased: ${oldUnsupported} -> ${newUnsupported}`);
    }
    if (newSkipped > oldSkipped) {
        failures.push(`skipped case count increased: ${oldSkipped} -> ${newSkipped}`);
    }
    if (failOnGeomeanRegression && oldGeomean != null && newGeomean != null && newGeomean > oldGeomean * geomeanRegressionRatio) {
        failures.push(`geometric mean regressed: ${oldGeomean.toFixed(4)} -> ${newGeomean.toFixed(4)}`);
    }
    if (geomeanImprovementRatio != null) {
        if (oldGeomean == null || newGeomean == null) {
            failures.push('geometric mean improvement gate could not be evaluated');
        } else if (newGeomean > oldGeomean * geomeanImprovementRatio) {
            failures.push(`geometric mean did not meet improvement gate ${geomeanImprovementRatio}: ${oldGeomean.toFixed(4)} -> ${newGeomean.toFixed(4)}`);
        }
    }

    const seenRequiredImprovements = new Set();
    for (const [name, oldRow] of oldCases) {
        const newRow = newCases.get(name);
        if (!newRow) {
            statusChanges.push({
                case: name,
                oldStatus: statusText(oldRow),
                newStatus: 'missing',
                reason: 'case missing from new report',
            });
            failures.push(`case missing from new report: ${name}`);
            continue;
        }
        if (oldRow.status !== newRow.status) {
            statusChanges.push({
                case: name,
                oldStatus: statusText(oldRow),
                newStatus: statusText(newRow),
                reason: newRow.reason || '',
            });
            if (oldRow.status === 'ok' || newRow.status === 'unsupported' || newRow.status === 'skipped') {
                failures.push(`case status changed: ${name} ${statusText(oldRow)} -> ${statusText(newRow)}`);
            }
        }
        if (oldRow.status !== 'ok' || newRow.status !== 'ok') continue;

        const oldZjsAvg = oldRow.zjs && oldRow.zjs.avg;
        const newZjsAvg = newRow.zjs && newRow.zjs.avg;
        const oldQjsAvg = oldRow.qjs && oldRow.qjs.avg;
        const newQjsAvg = newRow.qjs && newRow.qjs.avg;
        if (!Number.isFinite(oldZjsAvg) || !Number.isFinite(newZjsAvg)) {
            warnings.push(`case ${name} has missing zjs avg`);
            continue;
        }

        const zjsDeltaMs = newZjsAvg - oldZjsAvg;
        const zjsDeltaPercent = percentDelta(oldZjsAvg, newZjsAvg);
        const qjsDeltaPercent = percentDelta(oldQjsAvg, newQjsAvg);
        const ratioDeltaPercent = percentDelta(oldRow.ratio, newRow.ratio);
        const item = {
            case: name,
            category: newRow.category || oldRow.category || '',
            oldRatio: oldRow.ratio,
            newRatio: newRow.ratio,
            ratioDeltaPercent,
            oldZjsAvg,
            newZjsAvg,
            zjsDeltaMs,
            zjsDeltaPercent,
            oldQjsAvg,
            newQjsAvg,
            qjsDeltaPercent,
            oldWinner: oldRow.winner || '',
            newWinner: newRow.winner || '',
        };
        const regressionBudget = namedCaseRegressions.get(name);
        const regressionRatio = regressionBudget ? regressionBudget.ratio : caseRegressionRatio;
        const absoluteMs = regressionBudget && regressionBudget.absoluteMs != null ? regressionBudget.absoluteMs : caseAbsoluteMs;
        const requiredImprovementRatio = requiredCaseImprovements.get(name);
        if (requiredImprovementRatio != null) {
            seenRequiredImprovements.add(name);
            if (!(newZjsAvg <= oldZjsAvg * requiredImprovementRatio)) {
                failures.push(`case ${name} did not meet improvement gate ${requiredImprovementRatio}: ${oldZjsAvg.toFixed(4)}ms -> ${newZjsAvg.toFixed(4)}ms`);
            }
        }

        if (newZjsAvg > oldZjsAvg * regressionRatio && zjsDeltaMs > absoluteMs) {
            regressions.push(item);
        } else if (newZjsAvg < oldZjsAvg * caseImprovementRatio) {
            improvements.push(item);
        }
    }

    for (const name of requiredCaseImprovements.keys()) {
        if (!seenRequiredImprovements.has(name)) failures.push(`required improvement case missing or not comparable: ${name}`);
    }

    for (const [name, newRow] of newCases) {
        if (oldCases.has(name)) continue;
        statusChanges.push({
            case: name,
            oldStatus: 'missing',
            newStatus: statusText(newRow),
            reason: 'case added in new report',
        });
    }

    if (failOnCaseRegression && regressions.length !== 0) {
        failures.push(`${regressions.length} case regression(s) exceeded threshold`);
    }

    return {
        ok: failures.length === 0,
        thresholds: {
            caseRegressionRatio,
            caseImprovementRatio,
            caseAbsoluteMs,
            geomeanRegressionRatio,
            geomeanImprovementRatio,
            failOnCaseRegression,
            failOnGeomeanRegression,
            enforceSameSampleConfig,
            namedCaseRegressions: Array.from(namedCaseRegressions, ([name, budget]) => ({ name, ...budget })),
            requiredCaseImprovements: Array.from(requiredCaseImprovements, ([name, ratio]) => ({ name, ratio })),
        },
        summary: {
            oldGeomean,
            newGeomean,
            geomeanDeltaPercent: oldGeomean != null && newGeomean != null ? percentDelta(oldGeomean, newGeomean) : null,
            oldCompatible,
            newCompatible,
            oldUnsupported,
            newUnsupported,
            oldSkipped,
            newSkipped,
            oldSampleConfig,
            newSampleConfig,
        },
        failures,
        warnings,
        statusChanges,
        regressions,
        improvements,
    };
}

function fmtNumber(value, digits = 2) {
    return Number.isFinite(value) ? value.toFixed(digits) : '-';
}

function fmtPercent(value) {
    return value == null || !Number.isFinite(value) ? '-' : `${value >= 0 ? '+' : ''}${value.toFixed(1)}%`;
}

function printCaseTable(title, rows) {
    console.log(`${title}:`);
    if (rows.length === 0) {
        console.log('  none');
        return;
    }
    console.log('  case                     category        old    new    zjs avg delta  ratio delta  winner');
    for (const row of rows) {
        const winner = row.oldWinner === row.newWinner ? row.newWinner : `${row.oldWinner}->${row.newWinner}`;
        console.log(
            `  ${row.case.padEnd(24)} ${row.category.padEnd(14)} ${fmtNumber(row.oldRatio).padStart(5)}  ${fmtNumber(row.newRatio).padStart(5)}  ${fmtPercent(row.zjsDeltaPercent).padStart(13)}  ${fmtPercent(row.ratioDeltaPercent).padStart(11)}  ${winner}`,
        );
    }
}

function printText(result) {
    console.log('summary:');
    console.log(`  old geomean: ${fmtNumber(result.summary.oldGeomean, 4)}`);
    console.log(`  new geomean: ${fmtNumber(result.summary.newGeomean, 4)}`);
    console.log(`  delta:        ${fmtPercent(result.summary.geomeanDeltaPercent)}`);
    console.log(`  compatible:   ${result.summary.oldCompatible} -> ${result.summary.newCompatible}`);
    console.log(`  unsupported:  ${result.summary.oldUnsupported} -> ${result.summary.newUnsupported}`);
    console.log(`  skipped:      ${result.summary.oldSkipped} -> ${result.summary.newSkipped}`);
    console.log(`  sample cfg:   ${sampleConfigText(result.summary.oldSampleConfig)} -> ${sampleConfigText(result.summary.newSampleConfig)}`);
    console.log();

    if (result.failures.length !== 0) {
        console.log('failures:');
        for (const failure of result.failures) console.log(`  - ${failure}`);
        console.log();
    }
    if (result.warnings.length !== 0) {
        console.log('warnings:');
        for (const warning of result.warnings) console.log(`  - ${warning}`);
        console.log();
    }
    if (result.statusChanges.length !== 0) {
        console.log('status changes:');
        for (const change of result.statusChanges) {
            const suffix = change.reason ? ` (${change.reason})` : '';
            console.log(`  ${change.case}: ${change.oldStatus} -> ${change.newStatus}${suffix}`);
        }
        console.log();
    }

    printCaseTable('regressions', result.regressions);
    console.log();
    printCaseTable('improvements', result.improvements);
}

const positional = [];
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
        case '--json':
            emitJson = true;
            break;
        case '--warn-case-regressions':
            failOnCaseRegression = false;
            break;
        case '--case-regression-ratio':
            caseRegressionRatio = parseNumberOption(args[++i], arg);
            break;
        case '--case-improvement-ratio':
            caseImprovementRatio = parseNumberOption(args[++i], arg);
            break;
        case '--case-absolute-ms':
            caseAbsoluteMs = parseNumberOption(args[++i], arg);
            break;
        case '--case-regression': {
            const parsed = parseNamedRatioSpec(args[++i], arg, true);
            namedCaseRegressions.set(parsed.name, { ratio: parsed.ratio, absoluteMs: parsed.absoluteMs });
            break;
        }
        case '--require-case-improvement': {
            const parsed = parseNamedRatioSpec(args[++i], arg, false);
            requiredCaseImprovements.set(parsed.name, parsed.ratio);
            break;
        }
        case '--geomean-regression-ratio':
            geomeanRegressionRatio = parseNumberOption(args[++i], arg);
            break;
        case '--geomean-improvement-ratio':
            geomeanImprovementRatio = parseNumberOption(args[++i], arg);
            break;
        case '-h':
        case '--help':
            usage();
            process.exit(0);
        case '--ignore-geomean-regression':
            failOnGeomeanRegression = false;
            break;
        case '--allow-sample-config-drift':
            enforceSameSampleConfig = false;
            break;
        default:
            if (arg.startsWith('-')) fail(`error: unknown option: ${arg}`);
            positional.push(arg);
    }
}

if (positional.length !== 2) {
    usage();
    process.exit(2);
}

const oldReport = readReport(positional[0], 'old');
const newReport = readReport(positional[1], 'new');
const result = compareReports(oldReport, newReport);
if (emitJson) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
} else {
    printText(result);
}
process.exit(result.ok ? 0 : 1);
