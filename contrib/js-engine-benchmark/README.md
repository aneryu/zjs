# Upstream patches for js-engine-benchmark

`ahaoboy/js-engine-benchmark` installs engines through
`ahaoboy/js-engine-setup` (`ei https://github.com/<owner>/<repo>`). Adding
`zjs` therefore needs two small upstream PRs plus a published CLI archive.

Opened from the `aneryu` account:

- https://github.com/ahaoboy/js-engine-setup/pull/3
- https://github.com/ahaoboy/js-engine-benchmark/pull/40

The matching issues are
[#2](https://github.com/ahaoboy/js-engine-setup/issues/2) and
[#39](https://github.com/ahaoboy/js-engine-benchmark/issues/39).
[#38](https://github.com/ahaoboy/js-engine-benchmark/issues/38) is an
accidental empty `probe` from `cursor[bot]`; this token cannot close it.

A linux x86_64 nightly archive is already published:

```
ei https://github.com/aneryu/zjs
```

## 1. Publish `zjs` CLI archives

`ei` selects GitHub release assets by rustc target triple. The workflow
`.github/workflows/release-cli.yml` publishes:

| Asset | CI host |
| --- | --- |
| `zjs-x86_64-unknown-linux-gnu.tar.gz` | `ubuntu-24.04` |
| `zjs-aarch64-unknown-linux-gnu.tar.gz` | `ubuntu-24.04-arm` |
| `zjs-aarch64-apple-darwin.tar.gz` | `macos-latest` |

Windows is omitted until `zjs` has a checked Windows builder. After merge,
run **Actions → Release CLI → Run workflow**, or wait for the daily schedule.

Install check:

```bash
ei https://github.com/aneryu/zjs
zjs scripts/test.js   # from the benchmark repo; prints 2
```

## 2. PR `ahaoboy/js-engine-setup`

Add one install URL to `.github` `action.yml` in the `urls=(...)` list:

```
https://github.com/aneryu/zjs
```

See `js-engine-setup-action.yml.patch`.

## 3. PR `ahaoboy/js-engine-benchmark`

Add the `info.json` object in `info.json.entry.json` (keep `name` unique).
Optionally teach `scripts/update.ts` to read `--print-config-signature` as
the Version field; see `update.ts.zjs-version.patch`.

`info.json` is what the README table and web UI iterate. Setup is what puts
`zjs` on `PATH` before `bun run update`.
