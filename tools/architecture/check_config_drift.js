#!/usr/bin/env node
// QCP-1 negative drift gate.
//
// WHAT IT PROVES. `src/config_signature.zig`'s `attest()` runs at compile time
// in every engine-bearing artifact and compares the configuration the code
// ACTUALLY has (read from the declarations the engine consumes) against the
// configuration the build graph requested. That assertion is worth exactly
// what its ability to fail is worth -- and one-time forced-drift evidence
// decays. A later refactor can delete the `comptime` block, or make the
// "actual" side read the expectation, and nothing would go red again.
//
// So this gate makes the ability to fail itself machine-checked, permanently:
//
//   HALF 1/5  NEGATIVE (compiler)  wrong `compiler` component  -> must FAIL
//   HALF 2/5  NEGATIVE (layout)    wrong `layout` component    -> must FAIL
//   HALF 3/5  POSITIVE             correct expectation         -> must SUCCEED
//   HALF 4/5  POSITIVE (.plain)    -Dzjs_v2_layout=plain with a
//                                  `layout=plain` expectation  -> must SUCCEED
//   HALF 5/5  NEGATIVE (optimize)  wrong `optimize` component, against the
//                                  artifact that FOLLOWS -Doptimize
//                                                              -> must FAIL
//
// Both directions are mandatory. The negative halves alone would be satisfied
// by a check that always fails; the positive halves alone would be satisfied
// by a check that never fails.
//
// `compiler` and `layout` specifically, because those two are the release
// backend and the bytecode layout: the two settings the switch ruling made
// load-bearing and the two a nested build has actually been observed to lose.
//
// HALF 4 is also the `.plain` diagnostic's self-proof. The SAME expectation
// string (`layout=plain`) must FAIL against a `short` build in half 2 and
// SUCCEED against a `plain` build in half 4. That pair can only both hold if
// the value being compared is the one `resolve_labels.default_layout` hands to
// the resolver, not the `-D` string sitting beside it. A `.plain` switch that
// existed in name while being ignored in fact -- which would silently
// invalidate every A/B diagnostic run with it -- fails half 4.
//
// A negative half is only accepted when the child failed AND its output
// carries the attestation's own diagnostic naming the drifted component. A
// build that fails for an unrelated reason (a syntax error, a missing file)
// is reported as an inconclusive gate failure, never as evidence.

const { spawnSync } = require("node:child_process");
const path = require("node:path");

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    if (!key.startsWith("--")) fail(`unexpected argument '${key}'`);
    const value = argv[i + 1];
    if (value === undefined) fail(`option '${key}' requires a value`);
    out[key.slice(2)] = value;
  }
  return out;
}

function fail(message) {
  console.error(`config-drift-gate: ${message}`);
  process.exit(1);
}

const args = parseArgs(process.argv.slice(2));
for (const required of ["zig", "step", "optimize-step", "expect", "compiler", "layout"]) {
  if (!args[required]) fail(`missing required option --${required}`);
}
const buildRoot = path.resolve(args["build-root"] || process.cwd());
const seed = args.seed || "0";

// The signature grammar is `zjs-config-<n>:<field>=<value>,...`; the gate only
// ever rewrites one field at a time and leaves the rest byte for byte.
// Every field is preceded by the version separator ':' or by a field
// separator ','; anchoring on that is what keeps `compiler=` from matching
// inside some other field's value.
function componentValue(signature, field) {
  const match = signature.match(new RegExp(`[:,]${field}=([^,]*)`));
  return match ? match[1] : null;
}

function withComponent(signature, field, value) {
  const current = componentValue(signature, field);
  if (current === null) fail(`expectation '${signature}' has no '${field}' component`);
  return signature.replace(
    new RegExp(`([:,]${field}=)[^,]*`),
    (_, prefix) => `${prefix}${value}`,
  );
}

const expected = args.expect;
if (!expected.startsWith("zjs-config-v2:")) {
  fail(`expectation '${expected}' is not a zjs-config-v2 signature`);
}

// A wrong value must be a DIFFERENT legal value, not nonsense: the point is to
// simulate a build that resolved the other supported backend/layout, which is
// the real defect, rather than a build that resolved garbage.
const wrongCompiler = componentValue(expected, "compiler") === "legacy" ? "v2" : "legacy";
const wrongLayout = componentValue(expected, "layout") === "plain" ? "short" : "plain";
// ReleaseSafe against Debug is the exact pairing the ruling names: same
// compiler, same layout, same representation, different oracle.
const wrongOptimize = componentValue(expected, "optimize") === "Debug" ? "ReleaseSafe" : "Debug";

// Every component of the signature is passed explicitly to the child, because
// a nested `zig build` starts from the DEFAULTS for every option the parent
// was given. Inheriting silently is the original defect this whole mechanism
// exists to close, so nothing here is inherited.
function baseOptions(layoutOverride) {
  const options = [
    `-Dzjs_compiler=${args.compiler}`,
    `-Dzjs_v2_layout=${layoutOverride || args.layout}`,
    `-Dzjs_nan_boxing=${args["nan-boxing"] || "false"}`,
    `-Dzjs_force_gc=${args["force-gc"] || "false"}`,
    `-Dzjs_ownership_audit=${args["ownership-audit"] || "false"}`,
    `-Dzjs_test_seed=${seed}`,
  ];
  if (args.optimize) options.push(`-Doptimize=${args.optimize}`);
  return options;
}

function runChild(expectConfig, layoutOverride, step) {
  const argv = [
    "build",
    step || args.step,
    ...baseOptions(layoutOverride),
    `-Dzjs_expect_config=${expectConfig}`,
    "--seed",
    seed,
  ];
  const result = spawnSync(args.zig, argv, {
    cwd: buildRoot,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) fail(`failed to spawn '${args.zig} build': ${result.error.message}`);
  return {
    command: `${args.zig} ${argv.join(" ")}`,
    status: result.status,
    output: `${result.stdout || ""}${result.stderr || ""}`,
  };
}

const halves = [
  {
    label: "HALF 1/5 NEGATIVE (component: compiler)",
    expect: "FAILURE",
    why: `expectation says compiler=${wrongCompiler}, build resolves compiler=${componentValue(expected, "compiler")}`,
    signature: withComponent(expected, "compiler", wrongCompiler),
    layout: null,
    mustFail: true,
    mustMention: ["zjs configuration drift", "compiler: expected"],
  },
  {
    label: "HALF 2/5 NEGATIVE (component: layout)",
    expect: "FAILURE",
    why: `expectation says layout=${wrongLayout}, build resolves layout=${componentValue(expected, "layout")}`,
    signature: withComponent(expected, "layout", wrongLayout),
    layout: null,
    mustFail: true,
    mustMention: ["zjs configuration drift", "layout: expected"],
  },
  {
    label: "HALF 3/5 POSITIVE (correct expectation)",
    expect: "SUCCESS",
    why: "expectation matches the configuration the build resolves",
    signature: expected,
    layout: null,
    mustFail: false,
    mustMention: [],
  },
  {
    label: "HALF 4/5 POSITIVE (.plain diagnostic self-proof)",
    expect: "SUCCESS",
    why:
      "same layout=plain expectation that HALF 2 required to FAIL against a short build; " +
      "it must SUCCEED against -Dzjs_v2_layout=plain, which is only possible if the layout " +
      "reported is the one the resolver consumes",
    signature: withComponent(expected, "layout", "plain"),
    layout: "plain",
    mustFail: false,
    mustMention: [],
  },
  // The optimize half must run against an artifact that FOLLOWS -Doptimize.
  // The probe used by halves 1-4 pins Debug, and a pinned artifact reporting
  // its pinned mode is not drift, so it cannot express this case at all.
  {
    label: "HALF 5/5 NEGATIVE (component: optimize)",
    expect: "FAILURE",
    why:
      `expectation says optimize=${wrongOptimize}, build resolves optimize=${componentValue(expected, "optimize")}; ` +
      "this is the 'parent asked for ReleaseSafe, child actually built Debug' case, which " +
      "leaves compiler/layout/repr identical and used to read as green",
    signature: withComponent(expected, "optimize", wrongOptimize),
    layout: null,
    step: args["optimize-step"],
    mustFail: true,
    mustMention: ["zjs configuration drift", "optimize: expected"],
  },
];

// Half 4 is only a self-proof when half 2's expectation really is layout=plain
// (i.e. the build under test resolves `short`). Under a `-Dzjs_v2_layout=plain`
// parent the two coincide and the pair degenerates; say so rather than claim
// evidence that was not produced.
const plainSelfProofIsLive = componentValue(expected, "layout") === "short";

let failures = 0;
for (const half of halves) {
  console.log("");
  console.log(`[config-drift-gate] ${half.label}`);
  console.log(`[config-drift-gate]   expecting: ${half.expect}`);
  console.log(`[config-drift-gate]   reason:    ${half.why}`);
  console.log(`[config-drift-gate]   expectation passed down: ${half.signature}`);
  if (half.mustFail) {
    console.log(
      "[config-drift-gate]   NOTE: a build error printed below is the EXPECTED result of this half, not a real failure.",
    );
  }

  const run = runChild(half.signature, half.layout, half.step);
  const succeeded = run.status === 0;

  if (half.mustFail && succeeded) {
    failures += 1;
    console.error(
      `[config-drift-gate] ${half.label}: FAILED -- the build SUCCEEDED with a deliberately wrong expectation.`,
    );
    console.error(
      "[config-drift-gate]   The per-artifact configuration attestation is not detecting drift: it has been",
    );
    console.error(
      "[config-drift-gate]   removed, weakened, or is reading the expectation as its own 'actual' value.",
    );
    console.error(`[config-drift-gate]   command: ${run.command}`);
    continue;
  }

  if (!half.mustFail && !succeeded) {
    failures += 1;
    console.error(
      `[config-drift-gate] ${half.label}: FAILED -- the build FAILED with the correct expectation.`,
    );
    console.error(`[config-drift-gate]   command: ${run.command}`);
    console.error(indent(run.output));
    continue;
  }

  if (half.mustFail) {
    const missing = half.mustMention.filter((needle) => !run.output.includes(needle));
    if (missing.length !== 0) {
      failures += 1;
      console.error(
        `[config-drift-gate] ${half.label}: INCONCLUSIVE -- the build failed, but not with the attestation's diagnostic.`,
      );
      console.error(
        `[config-drift-gate]   missing from the output: ${missing.map((m) => JSON.stringify(m)).join(", ")}`,
      );
      console.error(
        "[config-drift-gate]   A build that fails for an unrelated reason is not evidence that drift is detected.",
      );
      console.error(`[config-drift-gate]   command: ${run.command}`);
      console.error(indent(run.output));
      continue;
    }
    console.log(
      `[config-drift-gate] ${half.label}: OK -- failed as required, with the drift diagnostic.`,
    );
    // Deduplicated: an artifact whose root and whose sub-roots all attest
    // reports the same drift once per attesting file, which is reassuring but
    // unreadable. Report how many attestations fired, then the distinct lines.
    const seen = new Set();
    let attestations = 0;
    for (const line of run.output.split("\n")) {
      const text = line.trim();
      if (text.startsWith("artifact:")) attestations += 1;
      if (
        text.startsWith("artifact:") ||
        text.startsWith("expected:") ||
        text.startsWith("actual:") ||
        / expected .*, actual /.test(text)
      ) {
        seen.add(text);
      }
    }
    console.log(`[config-drift-gate]     ${attestations} artifact attestation(s) fired`);
    for (const text of seen) console.log(`[config-drift-gate]     ${text}`);
    continue;
  }

  console.log(`[config-drift-gate] ${half.label}: OK -- succeeded as required.`);
}

console.log("");
if (!plainSelfProofIsLive) {
  console.log(
    "[config-drift-gate] NOTE: this build already resolves layout=plain, so halves 2 and 4 do not form " +
      "the short-vs-plain contrast. Run the gate from a default (layout=short) build for the full .plain self-proof.",
  );
}
if (failures !== 0) {
  console.error(`[config-drift-gate] ${failures} of ${halves.length} halves did not behave as required.`);
  process.exit(1);
}
console.log(`[config-drift-gate] all ${halves.length} halves behaved as required.`);

function indent(text) {
  return text
    .split("\n")
    .map((line) => `      | ${line}`)
    .join("\n");
}
