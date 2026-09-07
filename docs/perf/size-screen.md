# Size and source ablation screen

`tools/maintainability/size_screen.py` freezes the candidate once and compares it
with a reusable baseline before expensive performance work. It measures disk
bytes and physical source lines. `CONTINUE` only means the preregistered size or
source saving was achieved; it is **not** a correctness or performance verdict.
The validation authority remains [verification-policy.md](../verification-policy.md).
The existing GC Stage 0 implementation is unchanged.

## Freeze once per source state

For a source-only objective, reject low-value edits **before** building:

```sh
mise run source-screen -- .scratch/size-batch/baseline --min-lines 20
```

This compares the current Git source inventory against a verified frozen
baseline, defaults to the `engine` category, and accepts repeated
`--source-category` arguments. It requires Python and Git but invokes no compiler,
binutils, executable artifact, or build lock. Exit 3 means STOP; exit 0 only
means the source saving warrants a build; exit 2 means invalid inputs/evidence.
The output records both source identities and every category's line delta.
It makes no binary-size, configuration-parity, or correctness claim.

For CONTINUE, freeze the candidate below and check that its source
`content_sha256` matches the precheck's `candidate_source_sha256`; if edits have
continued, rerun the cheap precheck. Then use the normal frozen comparison and
applicable validation. The precheck is optional and cannot replace them.

Run from a Linux host with Python 3, Zig, GNU binutils (`strip`, `readelf`),
`timeout`, `flock`, and `taskset`. Only little-endian ELF64 native executables are
supported. The script executes the artifact to read its configuration signature.

```sh
python3 tools/maintainability/size_screen.py freeze \
  --out .scratch/size-batch/baseline
# Make one candidate change, then freeze its evidence:
python3 tools/maintainability/size_screen.py freeze \
  --out .scratch/size-batch/candidate
```

The default is explicitly `ReleaseFast` and builds the production `zjs` target,
preserving its artifact name and cache identity. For the separate optimization-mode
experiment, pass `--optimize ReleaseSmall` (builds the separate `zjs-size` target). The owned build is:

```text
timeout --kill-after=5s 1200 flock -x /tmp/zjs-host-heavy.lock taskset -c <build-cpus> \
  zig build <zjs-or-zjs-size> -Doptimize=<mode> --prefix <snapshot>/build -j32 --summary all
```

`--build-cpus` defaults to `ZJS_BUILD_CPUS`, then `5-8,15-18`. The host lock covers
compilation. The isolated install prefix prevents another build from replacing
the artifact being frozen; the production `zig-out/bin/zjs` is not touched.
Build cache reuse is allowed: Zig checks the current inputs through its build
graph. Supplying an arbitrary existing binary is deliberately unsupported.

A snapshot directory must be new, and git-ignored if inside the repository.
Failed attempts retain diagnostics but are not valid snapshots. Use a new path
when retrying. Source inventory before and after compilation must match; stop
other source edits while freezing. The manifest records Git revision/status,
per-file hashes, source totals, the exact command and build log hash, Zig/binutils
versions, full Zig native target block (CPU/features/OS ABI, queried with the
same CPU affinity as the build), ELF machine, and the actual runtime configuration signature. A mismatch
between requested mode and the signature rejects the snapshot.

The original binary and a **post-link stripped copy** are frozen read-only, with
SHA-256 identities verified on every comparison. The build log and manifest have
identities too. These protect against accidental changes, not deliberate rewriting
of the snapshot and its hashes. The intermediate install prefix is removed after
successful freezing; retained binaries can be used for later measurements.
Frozen binaries retain executable permission and can be used directly by a
measurement harness. Stripping must preserve the runtime signature and every
allocated file-backed section's address and contents.

## Preregister a saving and compare

Choose the objective and threshold before implementing the candidate:

```sh
python3 tools/maintainability/size_screen.py compare \
  .scratch/size-batch/baseline .scratch/size-batch/candidate \
  --objective binary --min-bytes 4096

python3 tools/maintainability/size_screen.py compare \
  .scratch/size-batch/baseline .scratch/size-batch/candidate \
  --objective source --min-lines 100 --source-category engine
```

Exit codes: **0** = CONTINUE, **3** = STOP (saving below the stated minimum),
**2** = invalid evidence or arguments. Thresholds must be positive. Negative
deltas mean a reduction. Both objectives report the other dimension without
allowing it to offset failure of the chosen objective. To record both parent and
batch-baseline differences, invoke compare with each frozen baseline.

ELF target, native codegen target, Zig version, and strip version must match. Configuration signatures
must also match, unless the intentional optimization-mode experiment supplies
`--allow-cross-config`; that difference remains labeled in the output.

## Accounting boundaries

Binary totals are the actual stripped file length. Every named section is
reported, including `.text.zjs.op_handlers`; executable bytes sum all sections
with the ELF executable flag. `NOBITS` sections such as `.bss` consume **zero disk
bytes** and have a separate memory-size total. Headers, padding, and other
non-section bytes are a residual, so totals reconcile with the file length.
This is file size, not RSS, allocation footprint, or source-symbol attribution.

Source membership comes from tracked files plus nonignored untracked files.
Deleted tracked files are explicit manifest entries. All these files contribute
to the content identity; physical-line totals count `.zig`, `.c`, `.h`, `.cpp`,
`.hpp`, `.py`, `.js`, `.ts`, `.sh`, and `build.zig.zon` under these categories:

| Category | Membership |
|---|---|
| `engine` | `src/`, excluding the test/generated categories below |
| `generated` | Unicode `src/libs/unicode/data.zig` and generated `src/abi/fun_native_abi.h` |
| `tests` | `src/tests/`, `tests/`, `*_tests.zig`, `src/compiler/{tests,test_entry}.zig` |
| `build` | `build/`, `build.zig`, `build.zig.zon` |
| `tools` | `tools/` |
| `other_source` | Remaining files with the listed suffixes |

Lines include blanks, comments, generated tables, and inline tests. This is an
explicit reproducible physical-line count, **not production SLOC**. Source
objectives default to `engine`; repeat `--source-category` to intentionally
include other categories. Submodule contents are excluded from line totals;
the manifest records their index pin and initialized checkout revision/status.
Ignored files and external build dependencies are outside the inventory. Freeze
assumes the normal repository build inputs; do not inject ignored source files
or external build configuration into an experiment.

Targeted tool verification (real C/ELF fixtures, no engine compilation):

After an exact source rollback, `mise run size-verify -- <snapshot>` can verify
reuse without another optimized build. It checks sealed file hashes, owned-build
provenance, the complete current inventory, requested mode (default ReleaseFast),
Zig version and native target. Exit 0 means REUSE; 3 means REBUILD; 2 means invalid
evidence/environment. Dirty submodules cannot establish content equality from
status alone and are rejected for reuse. The snapshot remains unchanged and
retains its original build evidence; this is not a new build or test pass.
Documentation/tool edits also change the inventory and prevent reuse. Normal
build-input assumptions above still apply: ignored or external injected inputs
are not covered. Use `--optimize ReleaseSmall` only for that experimental mode.

```sh
python3 -m unittest discover -s tools/maintainability -p test_size_screen.py -v
```
