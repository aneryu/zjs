#!/usr/bin/env python3
"""Score zjs with the ahaoboy/js-engine-benchmark v8-v7 protocol.

The published table at https://github.com/ahaoboy/js-engine-benchmark runs one
bundled `dist/run.js` per engine and reads the suite's own `Name: <int>` lines
(higher is better). The headline `Score` is the geometric mean of the eight
throughput benches. This runner exists so that local scoring uses that same
invocation and parser rather than a re-improvised Octane/zoo wrapper.

Usage:
    python3 tools/perf/js_engine_benchmark/run.py \\
        --zjs zig-out/bin/zjs \\
        --engine qjs=/path/to/qjs \\
        --output /tmp/js-engine-benchmark.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

SUITE_REPO = "https://github.com/ahaoboy/js-engine-benchmark"
# Pin the checkout that produced the 2026-08-18 published ubuntu table.
SUITE_COMMIT = "4d1d79e33129659e068285b9798d19c0cb7d15b7"

BENCHES = [
    "Richards",
    "DeltaBlue",
    "Crypto",
    "RayTrace",
    "EarleyBoyer",
    "RegExp",
    "Splay",
    "NavierStokes",
]

LOAD_RE = re.compile(r"load\('([^']+)'\);")


class RunFailure(RuntimeError):
    """One engine invocation did not produce a trustworthy score."""


def fail(message: str, code: int = 2) -> None:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(code)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_describe(repo: Path) -> dict[str, object]:
    def run(*args: str) -> str | None:
        try:
            out = subprocess.run(
                ["git", "-C", str(repo), *args],
                capture_output=True,
                text=True,
                check=True,
            )
            return out.stdout.strip()
        except Exception:
            return None

    return {
        "path": str(repo),
        "commit": run("rev-parse", "HEAD"),
        "dirty": bool(run("status", "--porcelain")),
    }


def cpu_model() -> str | None:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name") or line.startswith("Model"):
                return line.split(":", 1)[1].strip()
    except Exception:
        return None
    return None


def parse_scores(text: str) -> dict[str, int]:
    """Parse the official update.ts score lines, truncating toward zero."""
    lines = text.splitlines()
    offset = 0
    for line in lines:
        if "----" in line:
            offset = line.find("----")
            break
    allowed = set(BENCHES) | {"Score"}
    scores: dict[str, int] = {}
    for raw in lines:
        if not raw.strip() or "----" in raw or ":" not in raw:
            continue
        sliced = raw[offset:].replace('"', "").replace("INFO ", "")
        key, sep, value = sliced.partition(":")
        if not sep:
            continue
        key = key.strip()
        if key not in allowed:
            continue
        token = value.strip().split()[0] if value.strip() else ""
        try:
            scores[key] = int(float(token))
        except ValueError:
            continue
    return scores


def geomean(values: list[float]) -> float:
    if not values:
        raise ValueError("geomean of empty list")
    if any(value <= 0 for value in values):
        raise ValueError("geomean requires positive values")
    return math.exp(sum(math.log(value) for value in values) / len(values))


def score_per_mb(score: int, size_bytes: int) -> int:
    if size_bytes <= 0:
        return 0
    return int(score / size_bytes * 1024 * 1024)


def file_size(path: Path) -> int:
    return path.stat().st_size


def dll_size(path: Path) -> int:
    """Sum non-system shared objects reported by ldd, matching update.ts."""
    try:
        output = subprocess.run(
            ["ldd", str(path)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
    except FileNotFoundError:
        return 0
    total = 0
    for line in output.splitlines():
        if "=>" not in line:
            continue
        dep = line.split("=>", 1)[1].strip().split(" (", 1)[0]
        if not dep:
            continue
        if (
            dep.startswith("/lib/")
            or dep.startswith("/lib64/")
            or dep.startswith("linux-")
        ):
            continue
        dep_path = Path(dep)
        if dep_path.is_file():
            total += dep_path.stat().st_size
    return total


def bundle_run_js(suite_root: Path) -> str:
    """Inline every `load('file.js')` the way scripts/build.ts does."""
    code_root = suite_root / "v8-v7"
    run_path = code_root / "run.js"
    if not run_path.is_file():
        raise FileNotFoundError(f"missing {run_path}")
    run_content = run_path.read_text()
    matches = list(LOAD_RE.finditer(run_content))
    if not matches:
        raise RunFailure(f"{run_path} contains no load() calls")
    bundled = run_content
    for match in matches:
        name = match.group(1)
        source = (code_root / name).read_text()
        bundled = bundled.replace(match.group(0), source, 1)
    if LOAD_RE.search(bundled):
        raise RunFailure("bundled run.js still contains load() calls")
    return bundled


def ensure_suite(suite_dir: Path | None, cache_dir: Path) -> Path:
    if suite_dir is not None:
        if not (suite_dir / "v8-v7" / "run.js").is_file():
            fail(f"--suite {suite_dir} has no v8-v7/run.js")
        return suite_dir
    if (cache_dir / "v8-v7" / "run.js").is_file():
        commit = git_describe(cache_dir).get("commit")
        if commit == SUITE_COMMIT:
            return cache_dir
    cache_dir.parent.mkdir(parents=True, exist_ok=True)
    if cache_dir.exists():
        subprocess.run(["rm", "-rf", str(cache_dir)], check=True)
    subprocess.run(
        ["git", "clone", "--depth", "1", SUITE_REPO, str(cache_dir)],
        check=True,
    )
    # A depth-1 clone of main is enough when SUITE_COMMIT is still the tip.
    # Fetch the pin if the default branch has moved.
    current = git_describe(cache_dir).get("commit")
    if current != SUITE_COMMIT:
        subprocess.run(
            ["git", "-C", str(cache_dir), "fetch", "--depth", "1", "origin", SUITE_COMMIT],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(cache_dir), "checkout", SUITE_COMMIT],
            check=True,
        )
    return cache_dir


def run_engine(binary: Path, script: Path, timeout: int) -> tuple[str, float]:
    started = time.monotonic()
    try:
        proc = subprocess.run(
            [str(binary), str(script)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise RunFailure(f"{binary} timed out after {timeout}s") from exc
    elapsed = time.monotonic() - started
    if proc.returncode != 0:
        raise RunFailure(
            f"{binary} exited {proc.returncode}\n{proc.stderr or proc.stdout}"
        )
    return proc.stdout, elapsed


def parse_engine_spec(raw: str) -> tuple[str, Path]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError(
            f"engine spec must be name=path, got {raw!r}"
        )
    name, path = raw.split("=", 1)
    name = name.strip()
    if not name:
        raise argparse.ArgumentTypeError("engine name must not be empty")
    return name, Path(path).expanduser().resolve()


def measure_one(name: str, binary: Path, script: Path, timeout: int) -> dict[str, object]:
    if not binary.is_file():
        raise RunFailure(f"missing binary {binary}")
    if not os.access(binary, os.X_OK):
        mode = binary.stat().st_mode
        if not mode & stat.S_IXUSR:
            raise RunFailure(f"{binary} is not executable")
    stdout, elapsed = run_engine(binary, script, timeout)
    scores = parse_scores(stdout)
    missing = [bench for bench in (*BENCHES, "Score") if bench not in scores]
    if missing:
        raise RunFailure(
            f"{name} printed no parseable score for {', '.join(missing)}\n{stdout}"
        )
    exe = file_size(binary)
    dll = dll_size(binary)
    return {
        "name": name,
        "binary": str(binary),
        "sha256": sha256_of(binary),
        "exeSize": exe,
        "dllSize": dll,
        "totalSize": exe + dll,
        "timeSeconds": int(elapsed),
        "timeSecondsExact": elapsed,
        "scorePerMb": score_per_mb(scores["Score"], exe + dll),
        "scores": scores,
        "stdout": stdout,
    }


def build_artifact(
    *,
    engines: list[dict[str, object]],
    suite: Path,
    script: Path,
    zjs_repo: Path,
) -> dict[str, object]:
    rows = {engine["name"]: engine for engine in engines}
    return {
        "protocol": "ahaoboy/js-engine-benchmark v8-v7",
        "scoreDirection": "higher-is-better",
        "suite": {
            "repo": SUITE_REPO,
            "pinnedCommit": SUITE_COMMIT,
            **git_describe(suite),
            "bundledScript": str(script),
            "bundledSha256": sha256_of(script),
        },
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
            "cpu": cpu_model(),
            "nproc": os.cpu_count(),
        },
        "zjsRepo": git_describe(zjs_repo),
        "benches": BENCHES,
        "engines": rows,
    }


def render_table(artifact: dict[str, object]) -> str:
    engines = artifact["engines"]
    names = list(engines)
    lines = [
        "| Field | " + " | ".join(names) + " |",
        "| --- | " + " | ".join("---" for _ in names) + " |",
    ]
    for field in ("exeSize", "totalSize", *BENCHES, "Score", "scorePerMb", "timeSeconds"):
        label = {
            "exeSize": "Exe size",
            "totalSize": "Total size",
            "scorePerMb": "Score/MB",
            "timeSeconds": "Time(s)",
        }.get(field, field)
        cells = []
        for name in names:
            engine = engines[name]
            if field in ("exeSize", "totalSize", "scorePerMb", "timeSeconds"):
                cells.append(str(engine[field]))
            else:
                cells.append(str(engine["scores"][field]))
        lines.append("| " + label + " | " + " | ".join(cells) + " |")
    if "zjs" in engines and "qjs" in engines:
        zjs = engines["zjs"]["scores"]
        qjs = engines["qjs"]["scores"]
        ratios = [zjs[bench] / qjs[bench] for bench in BENCHES]
        lines.extend(
            [
                "",
                f"zjs / qjs score: {zjs['Score'] / qjs['Score']:.4f}",
                f"zjs / qjs geomean of the eight benches: {geomean(ratios):.4f}",
            ]
        )
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zjs", type=Path, required=True, help="ReleaseFast zjs binary")
    parser.add_argument(
        "--engine",
        action="append",
        default=[],
        type=parse_engine_spec,
        help="extra engine as name=path (repeatable)",
    )
    parser.add_argument(
        "--suite",
        type=Path,
        help="js-engine-benchmark checkout (cloned to cache if omitted)",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(".zig-cache/js-engine-benchmark"),
        help="clone destination when --suite is omitted",
    )
    parser.add_argument("--timeout", type=int, default=180, help="per-engine timeout seconds")
    parser.add_argument("--output", type=Path, help="write the JSON artifact here")
    parser.add_argument("--keep-stdout", action="store_true", help="keep raw stdout in JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    zjs = args.zjs.expanduser().resolve()
    suite = ensure_suite(
        args.suite.resolve() if args.suite else None,
        args.cache_dir.expanduser().resolve(),
    )
    work = Path(".zig-cache/js-engine-benchmark-dist")
    work.mkdir(parents=True, exist_ok=True)
    script = work / "run.js"
    script.write_text(bundle_run_js(suite))

    measured: list[dict[str, object]] = []
    specs = [("zjs", zjs), *args.engine]
    for name, binary in specs:
        print(f"running {name}: {binary}", file=sys.stderr)
        result = measure_one(name, binary, script, args.timeout)
        print(
            f"{name}: Score {result['scores']['Score']} "
            f"Score/MB {result['scorePerMb']} "
            f"Time(s) {result['timeSeconds']}",
            file=sys.stderr,
        )
        measured.append(result)

    artifact = build_artifact(
        engines=measured,
        suite=suite,
        script=script,
        zjs_repo=Path(__file__).resolve().parents[3],
    )
    if not args.keep_stdout:
        for engine in artifact["engines"].values():
            engine.pop("stdout", None)

    table = render_table(artifact)
    print(table)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(artifact, indent=2) + "\n")
        print(f"wrote {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RunFailure as exc:
        fail(str(exc))
