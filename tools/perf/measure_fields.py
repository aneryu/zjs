#!/usr/bin/env python3
"""Measurement-field registry and lock/affinity launcher.

The field launcher is the canonical way to start a performance process:

    python3 tools/perf/measure_fields.py run --field b --layer single -- COMMAND

Field A/B jobs take a shared host-window token plus their field-exclusive
lock.  A host job takes the host token exclusively, so legacy host-window
jobs and both canonical field jobs exclude one another during the transition.

Separate field locks permit the contract's named coarse concurrent screens;
they do not attest verdict precision.  Concurrent results must be labelled
``resolution >= 0.5% (coarse/concurrent)``, and every pre-registered verdict
must still run serialized in a quiet field or host window.

``run --paired-simultaneous`` is a barrier-synchronised A/B calibration and
diagnostic mode.  It records both arms and holds the host lock exclusively,
but it has no verdict authority unless the measurement contract grants it.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence


HOST_LOCK = "/tmp/zjs-host-heavy.lock"
BUILD_CPUS = (5, 6, 7, 8, 15, 16, 17, 18)


@dataclass(frozen=True)
class MeasureField:
    name: str
    single_cpu: int
    topology_cpus: tuple[int, ...]
    lock_path: str
    l3_domain: str


FIELDS = {
    "a": MeasureField(
        name="a",
        single_cpu=9,
        topology_cpus=(5, 6, 7, 8),
        lock_path="/tmp/zjs-field-a.lock",
        l3_domain="A",
    ),
    "b": MeasureField(
        name="b",
        single_cpu=19,
        topology_cpus=(15, 16, 17, 18),
        lock_path="/tmp/zjs-field-b.lock",
        l3_domain="B",
    ),
    "host": MeasureField(
        name="host",
        single_cpu=19,
        topology_cpus=(15, 16, 17, 18),
        lock_path=HOST_LOCK,
        l3_domain="A+B quiet window",
    ),
}


def field_name(value: str | None = None, environ: dict[str, str] | None = None) -> str:
    env = os.environ if environ is None else environ
    name = value or env.get("ZJS_MEASURE_FIELD", "b")
    if name not in FIELDS:
        raise ValueError(f"unknown measurement field {name!r}; expected a, b, or host")
    return name


def field_spec(value: str | None = None, environ: dict[str, str] | None = None) -> MeasureField:
    return FIELDS[field_name(value, environ)]


def cpus_for(field: MeasureField, layer: str) -> tuple[int, ...]:
    if layer == "single":
        return (field.single_cpu,)
    if layer == "topology":
        return field.topology_cpus
    raise ValueError(f"unknown measurement layer {layer!r}; expected single or topology")


def cpu_list(cpus: Sequence[int]) -> str:
    return ",".join(str(cpu) for cpu in cpus)


def single_cpu(
    value: str | None,
    cpu_override: int | None,
    environ: dict[str, str] | None = None,
) -> tuple[MeasureField, int, bool]:
    """Resolve a single-core field while retaining the old --cpu override.

    Explicit noncanonical CPUs remain runnable for historical diagnostics, but
    callers must record ``field_conforming=False`` and cannot use them as a
    field-contract verdict.
    """
    field = field_spec(value, environ)
    cpu = field.single_cpu if cpu_override is None else cpu_override
    return field, cpu, cpu == field.single_cpu


def field_metadata(field: MeasureField, layer: str) -> dict[str, object]:
    cpus = cpus_for(field, layer)
    return {
        **asdict(field),
        "layer": layer,
        "cpus": list(cpus),
        "cpuList": cpu_list(cpus),
        "hostToken": HOST_LOCK,
        "hostTokenMode": "exclusive" if field.name == "host" else "shared",
        "buildCpus": list(BUILD_CPUS),
    }


def _open_lock(path: str) -> int:
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o666)
    os.set_inheritable(fd, True)
    return fd


def _fd_targets(fd_text: str | None, path: str) -> bool:
    if not fd_text or not fd_text.isdigit():
        return False
    try:
        target = os.readlink(f"/proc/self/fd/{int(fd_text)}")
    except OSError:
        return False
    return os.path.realpath(target) == os.path.realpath(path)


def lock_attested(field: MeasureField) -> bool:
    """Verify that the canonical launcher passed the expected lock FDs."""
    if os.environ.get("ZJS_MEASURE_LOCK_HELD") != "1":
        return False
    if os.environ.get("ZJS_MEASURE_FIELD") != field.name:
        return False
    if not _fd_targets(os.environ.get("ZJS_MEASURE_HOST_FD"), HOST_LOCK):
        return False
    if field.name == "host":
        return True
    return _fd_targets(os.environ.get("ZJS_MEASURE_FIELD_FD"), field.lock_path)


@contextmanager
def measurement_lock(field: MeasureField):
    """Acquire the transition-safe lock pair for a field-aware runner.

    The canonical launcher marks inherited locks in the environment; nested
    field-aware runners then reuse that ownership instead of self-deadlocking.
    """
    if os.environ.get("ZJS_MEASURE_LOCK_HELD") == "1":
        if not lock_attested(field):
            raise RuntimeError(
                "inherited measurement-lock environment lacks matching lock FDs"
            )
        yield
        return

    host_fd = _open_lock(HOST_LOCK)
    field_fd: int | None = None
    try:
        fcntl.flock(
            host_fd,
            fcntl.LOCK_EX if field.name == "host" else fcntl.LOCK_SH,
        )
        if field.name != "host":
            field_fd = _open_lock(field.lock_path)
            fcntl.flock(field_fd, fcntl.LOCK_EX)
        yield
    finally:
        if field_fd is not None:
            os.close(field_fd)
        os.close(host_fd)


def run_locked(field: MeasureField, cpus: tuple[int, ...], command: list[str]) -> None:
    if not command:
        raise ValueError("missing command after --")

    host_fd = _open_lock(HOST_LOCK)
    field_fd: int | None = None
    try:
        fcntl.flock(
            host_fd,
            fcntl.LOCK_EX if field.name == "host" else fcntl.LOCK_SH,
        )
        if field.name != "host":
            field_fd = _open_lock(field.lock_path)
            fcntl.flock(field_fd, fcntl.LOCK_EX)

        os.sched_setaffinity(0, set(cpus))
        env = os.environ.copy()
        env.update(
            {
                "ZJS_MEASURE_FIELD": field.name,
                "ZJS_MEASURE_LAYER": "single" if len(cpus) == 1 else "topology",
                "ZJS_MEASURE_CPUS": cpu_list(cpus),
                "ZJS_MEASURE_LOCK": field.lock_path,
                "ZJS_MEASURE_HOST_TOKEN": HOST_LOCK,
                "ZJS_MEASURE_LOCK_HELD": "1",
                "ZJS_MEASURE_HOST_FD": str(host_fd),
            }
        )
        if field_fd is not None:
            env["ZJS_MEASURE_FIELD_FD"] = str(field_fd)
        else:
            env.pop("ZJS_MEASURE_FIELD_FD", None)
        os.execvpe(command[0], command, env)
    finally:
        if field_fd is not None:
            os.close(field_fd)
        os.close(host_fd)


def split_paired_commands(command: list[str]) -> tuple[list[str], list[str]]:
    """Split the two commands around one explicit ``:::`` barrier marker."""
    if command.count(":::") != 1:
        raise ValueError(
            "paired simultaneous mode requires exactly one ::: command separator"
        )
    separator = command.index(":::")
    left = command[:separator]
    right = command[separator + 1 :]
    if not left or not right:
        raise ValueError("paired simultaneous mode requires two non-empty commands")
    return left, right


@contextmanager
def paired_measurement_locks():
    """Hold the whole host and both field locks for one simultaneous pair.

    A caller already launched through canonical field ``host`` may retain that
    exclusive host lock across a complete Latin-square experiment.  Any other
    inherited field is rejected rather than upgraded in place and deadlocked.
    """
    inherited = os.environ.get("ZJS_MEASURE_LOCK_HELD") == "1"
    owns_host = not inherited
    if inherited:
        if os.environ.get("ZJS_MEASURE_FIELD") != "host" or not lock_attested(
            FIELDS["host"]
        ):
            raise RuntimeError(
                "paired simultaneous mode can only reuse an attested exclusive host lock"
            )
        host_fd = int(os.environ["ZJS_MEASURE_HOST_FD"])
    else:
        host_fd = _open_lock(HOST_LOCK)
        fcntl.flock(host_fd, fcntl.LOCK_EX)

    field_fds: dict[str, int] = {}
    try:
        for name in ("a", "b"):
            fd = _open_lock(FIELDS[name].lock_path)
            field_fds[name] = fd
            fcntl.flock(fd, fcntl.LOCK_EX)
        yield host_fd, field_fds, inherited
    finally:
        for fd in field_fds.values():
            os.close(fd)
        if owns_host:
            os.close(host_fd)


def _read_exact(fd: int, size: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {size} paired child signals")
        readable, _, _ = select.select([fd], [], [], remaining)
        if not readable:
            continue
        chunk = os.read(fd, size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _paired_child(
    field: MeasureField,
    role: str,
    command: list[str],
    ready_fd: int,
    start_fd: int,
    result_fd: int,
    stdout_path: Path,
    stderr_path: Path,
    host_fd: int,
    field_fd: int,
    timeout: int,
) -> "NoReturn":  # type: ignore[valid-type]
    ready_sent = False
    result: dict[str, object] = {
        "field": field.name,
        "role": role,
        "cpu": field.single_cpu,
    }
    try:
        os.sched_setaffinity(0, {field.single_cpu})
        result["effectiveAffinity"] = sorted(os.sched_getaffinity(0))
        os.write(ready_fd, b"R")
        ready_sent = True
        if os.read(start_fd, 1) != b"S":
            raise RuntimeError("paired start barrier closed without a release token")

        env = os.environ.copy()
        env.update(
            {
                "ZJS_MEASURE_FIELD": field.name,
                "ZJS_MEASURE_LAYER": "single",
                "ZJS_MEASURE_CPUS": str(field.single_cpu),
                "ZJS_MEASURE_LOCK": field.lock_path,
                "ZJS_MEASURE_HOST_TOKEN": HOST_LOCK,
                "ZJS_MEASURE_HOST_TOKEN_MODE": "exclusive",
                "ZJS_MEASURE_LOCK_HELD": "1",
                "ZJS_MEASURE_HOST_FD": str(host_fd),
                "ZJS_MEASURE_FIELD_FD": str(field_fd),
                "ZJS_MEASURE_PAIRED_SIMULTANEOUS": "1",
            }
        )
        result["startedMonotonicNs"] = time.monotonic_ns()
        result["startedEpochNs"] = time.time_ns()
        timed_out = False
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            proc = subprocess.Popen(
                command,
                stdout=stdout,
                stderr=stderr,
                env=env,
                pass_fds=(host_fd, field_fd),
                start_new_session=True,
            )
            try:
                exit_code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    exit_code = proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    exit_code = proc.wait()
        result["endedMonotonicNs"] = time.monotonic_ns()
        result["endedEpochNs"] = time.time_ns()
        result["exitCode"] = exit_code
        result["timedOut"] = timed_out
    except Exception as error:
        if not ready_sent:
            try:
                os.write(ready_fd, b"E")
            except OSError:
                pass
        result["launcherError"] = f"{type(error).__name__}: {error}"
        result.setdefault("exitCode", 125)
        result.setdefault("timedOut", False)
        result.setdefault("endedMonotonicNs", time.monotonic_ns())
        result.setdefault("endedEpochNs", time.time_ns())
    try:
        payload = json.dumps(result, separators=(",", ":")).encode() + b"\n"
        os.write(result_fd, payload)
    finally:
        os._exit(0)


def run_paired_simultaneous(
    command_a: list[str],
    command_b: list[str],
    role_a: str,
    role_b: str,
    output: Path,
    timeout: int,
) -> bool:
    """Run one field-A/field-B pair behind a shared start barrier."""
    if timeout < 1:
        raise ValueError("--paired-timeout must be a positive integer")
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    with paired_measurement_locks() as (host_fd, field_fds, inherited_host):
        ready_r, ready_w = os.pipe()
        start_r, start_w = os.pipe()
        result_r, result_w = os.pipe()
        children: dict[str, int] = {}
        with tempfile.TemporaryDirectory(prefix="zjs-paired-sim-") as tmp:
            tmp_dir = Path(tmp)
            try:
                for name, role, command in (
                    ("a", role_a, command_a),
                    ("b", role_b, command_b),
                ):
                    pid = os.fork()
                    if pid == 0:
                        os.close(ready_r)
                        os.close(start_w)
                        os.close(result_r)
                        _paired_child(
                            FIELDS[name],
                            role,
                            command,
                            ready_w,
                            start_r,
                            result_w,
                            tmp_dir / f"{name}.stdout",
                            tmp_dir / f"{name}.stderr",
                            host_fd,
                            field_fds[name],
                            timeout,
                        )
                    children[name] = pid

                os.close(ready_w)
                os.close(start_r)
                os.close(result_w)
                ready = _read_exact(ready_r, 2, 30.0)
                released_monotonic_ns = time.monotonic_ns()
                released_epoch_ns = time.time_ns()
                os.write(start_w, b"SS")
                os.close(start_w)
                start_w = -1

                child_status: dict[str, int] = {}
                for name, pid in children.items():
                    _, status = os.waitpid(pid, 0)
                    child_status[name] = os.waitstatus_to_exitcode(status)
                raw_results = os.read(result_r, 65536).decode()
            finally:
                for name, pid in children.items():
                    try:
                        waited, _ = os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        waited = pid
                    if waited == 0:
                        os.kill(pid, signal.SIGTERM)
                        os.waitpid(pid, 0)
                for fd in (ready_r, ready_w, start_r, start_w, result_r, result_w):
                    if fd >= 0:
                        try:
                            os.close(fd)
                        except OSError:
                            pass

            arms: dict[str, dict[str, object]] = {}
            for line in raw_results.splitlines():
                if not line:
                    continue
                record = json.loads(line)
                name = str(record["field"])
                record["command"] = command_a if name == "a" else command_b
                record["stdout"] = (tmp_dir / f"{name}.stdout").read_bytes().decode(
                    errors="replace"
                )
                record["stderr"] = (tmp_dir / f"{name}.stderr").read_bytes().decode(
                    errors="replace"
                )
                started = int(record.get("startedMonotonicNs", 0))
                ended = int(record.get("endedMonotonicNs", started))
                record["durationNs"] = max(0, ended - started)
                record["supervisorExitCode"] = child_status.get(name)
                arms[name] = record

    complete = set(arms) == {"a", "b"}
    if complete:
        start_a = int(arms["a"]["startedMonotonicNs"])
        start_b = int(arms["b"]["startedMonotonicNs"])
        end_a = int(arms["a"]["endedMonotonicNs"])
        end_b = int(arms["b"]["endedMonotonicNs"])
        synchrony = {
            "startDeltaNs": abs(start_a - start_b),
            "endDeltaNs": abs(end_a - end_b),
            "overlapNs": max(0, min(end_a, end_b) - max(start_a, start_b)),
        }
    else:
        synchrony = None

    artifact = {
        "tool": "zjs-measure-fields",
        "schemaVersion": 1,
        "mode": "paired-simultaneous",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "hostToken": HOST_LOCK,
        "hostTokenMode": "exclusive",
        "inheritedHostLock": inherited_host,
        "barrier": {
            "readyCount": ready.count(b"R"),
            "releaseMonotonicNs": released_monotonic_ns,
            "releaseEpochNs": released_epoch_ns,
        },
        "fields": {
            name: {**field_metadata(FIELDS[name], "single"), "hostTokenMode": "exclusive"}
            for name in ("a", "b")
        },
        "arms": arms,
        "synchrony": synchrony,
    }
    output.write_text(json.dumps(artifact, indent=2) + "\n")

    success = (
        complete
        and ready == b"RR"
        and all(
            arm.get("exitCode") == 0
            and arm.get("supervisorExitCode") == 0
            and arm.get("effectiveAffinity") == [FIELDS[name].single_cpu]
            and "launcherError" not in arm
            for name, arm in arms.items()
        )
    )
    if synchrony is not None:
        print(
            "paired-simultaneous: "
            f"start_delta={synchrony['startDeltaNs']}ns "
            f"end_delta={synchrony['endDeltaNs']}ns "
            f"output={output}",
            file=sys.stderr,
        )
    return success


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="subcommand", required=True)

    describe = sub.add_parser("describe", help="print the field registry as JSON")
    describe.add_argument("--field", choices=tuple(FIELDS), default=None)
    describe.add_argument("--layer", choices=("single", "topology"), default="single")

    cpus_command = sub.add_parser("cpus", help="print the canonical taskset CPU list")
    cpus_command.add_argument("--field", choices=tuple(FIELDS), default=None)
    cpus_command.add_argument("--layer", choices=("single", "topology"), default="single")

    run = sub.add_parser("run", help="lock, pin, and exec a command")
    run.add_argument("--field", choices=tuple(FIELDS), default=None)
    run.add_argument("--layer", choices=("single", "topology"), default="single")
    run.add_argument(
        "--paired-simultaneous",
        action="store_true",
        help=(
            "diagnostically run field-A and field-B commands behind one barrier "
            "and exclusive host lock"
        ),
    )
    run.add_argument("--paired-output", type=Path)
    run.add_argument("--paired-role-a", default="arm-a")
    run.add_argument("--paired-role-b", default="arm-b")
    run.add_argument("--paired-timeout", type=int, default=900)
    run.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args()

    if args.subcommand == "run" and args.paired_simultaneous:
        if args.field is not None or args.layer != "single":
            parser.error(
                "--paired-simultaneous has fixed field A/B single-core placement; "
                "do not pass --field or --layer"
            )
        if args.paired_output is None:
            parser.error("--paired-simultaneous requires --paired-output")
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        try:
            command_a, command_b = split_paired_commands(command)
            success = run_paired_simultaneous(
                command_a,
                command_b,
                args.paired_role_a,
                args.paired_role_b,
                args.paired_output,
                args.paired_timeout,
            )
        except (OSError, RuntimeError, TimeoutError, ValueError) as error:
            print(f"measure-field: {error}", file=sys.stderr)
            return 2
        return 0 if success else 1

    try:
        field = field_spec(args.field)
        cpus = cpus_for(field, args.layer)
    except ValueError as error:
        parser.error(str(error))

    if args.subcommand == "describe":
        print(json.dumps(field_metadata(field, args.layer), indent=2))
        return 0
    if args.subcommand == "cpus":
        print(cpu_list(cpus))
        return 0

    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        run_locked(field, cpus, command)
    except (OSError, ValueError) as error:
        print(f"measure-field: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
