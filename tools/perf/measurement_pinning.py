"""CPU pinning and affinity verification shared by the measurement runners.

Both `zoo/run_zoo_compare.py` and `bench_v8/run_benchv8_compare.py` enforce the
same rule: pinning must be EFFECTIVE, not merely requested. An allowed CPU set
that merely contains the requested CPUs is not pinning, and a runner that
assumes its caller pinned correctly will silently produce numbers taken under
scheduler migration.

This module owns that rule once. It was a second copy in the bench-v8 runner
before 2026-08-20.
"""


import os


def effective_affinity() -> set[int]:
    return set(os.sched_getaffinity(0))


def parse_cpu_list(spec: str) -> list[int]:
    """Parse Linux cpulist syntax while preserving lane order."""
    cpus: list[int] = []
    seen: set[int] = set()
    for raw_part in spec.split(","):
        part = raw_part.strip()
        if not part:
            raise ValueError(f"invalid empty CPU-list component in {spec!r}")
        if "-" in part:
            bounds = part.split("-")
            if len(bounds) != 2 or not all(bound.isdigit() for bound in bounds):
                raise ValueError(f"invalid CPU range {part!r}")
            start, end = (int(bound) for bound in bounds)
            if end < start:
                raise ValueError(f"descending CPU range {part!r} is not allowed")
            values = range(start, end + 1)
        else:
            if not part.isdigit():
                raise ValueError(f"invalid CPU {part!r}")
            values = (int(part),)
        for cpu in values:
            if cpu in seen:
                raise ValueError(f"CPU {cpu} occurs more than once in {spec!r}")
            cpus.append(cpu)
            seen.add(cpu)
    if not cpus:
        raise ValueError("CPU list must not be empty")
    return cpus


def parse_cluster_pair(spec_a: str, spec_b: str) -> tuple[list[int], list[int]]:
    """Parse two equal-width, disjoint cluster cpulists.

    Equal width because lanes pair one cluster's CPU with the other's; disjoint
    because two engines sharing a core would measure the scheduler, not the
    engines.
    """
    cluster_a = parse_cpu_list(spec_a)
    cluster_b = parse_cpu_list(spec_b)
    if len(cluster_a) != len(cluster_b):
        raise ValueError(
            f"clusters must have equal widths; got {len(cluster_a)} and {len(cluster_b)} CPUs"
        )
    overlap = sorted(set(cluster_a) & set(cluster_b))
    if overlap:
        raise ValueError(f"clusters must be disjoint; overlap: {overlap}")
    return cluster_a, cluster_b


def affinity_error(expected: set[int], argv0: str) -> str | None:
    """Return an actionable message when the outer affinity is not exactly `expected`."""
    actual = effective_affinity()
    if actual == expected:
        return None
    requested = ",".join(str(cpu) for cpu in sorted(expected))
    return (
        f"error: outer affinity is {sorted(actual)}, expected exactly [{requested}].\n"
        f"Run under: taskset -c {requested} python3 {argv0} ..."
    )
