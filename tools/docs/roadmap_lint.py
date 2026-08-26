#!/usr/bin/env python3
"""Roadmap governance linter.

Validates docs/roadmap/work-items.yaml (the machine-readable source of truth)
and its consistency with docs/roadmap.md and the domain docs. Run from the
repository root:  python3 tools/docs/roadmap_lint.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY = os.path.join(ROOT, "docs", "roadmap", "work-items.yaml")
ROADMAP = os.path.join(ROOT, "docs", "roadmap.md")

# Phrases retired by governance verdicts. They must not reappear as current
# statements. Ledger/review-note references are pinned via the allowlist:
# (relative path, phrase) -> max occurrences permitted.
FORBIDDEN_PHRASES = [
    "与 Phase 0 并行",
    "批准立即执行",
    "同一 emitter 的两种驱动",
    "一次设计,两期交付",
    "一次设计，两期交付",
    "并发 receive LIFO",
    "无论 spike 结果都要建",
]
SCAN_DOCS = [
    "docs/roadmap.md",
    "docs/engine-evolution-plan.md",
    "docs/type-directed-optimization-plan.md",
    "docs/fun-native-plugin-design.md",
    "docs/fun-dev-hot-reload-design.md",
    "docs/process-model-design.md",
]
# Ledger sections (process-model §20 family) and review notes may cite retired
# phrases as history. Pin the permitted counts; any increase fails the lint.
ALLOWLIST = {
    # evolution L5 states "Phase 0 批准立即执行" — a current, valid statement
    # about Phase 0 (the retired claim was about Phase 0.5).
    ("docs/engine-evolution-plan.md", "批准立即执行"): 1,
    # typed plan's 1.0 review note quotes both retracted claims as history.
    ("docs/type-directed-optimization-plan.md", "同一 emitter 的两种驱动"): 1,
    ("docs/type-directed-optimization-plan.md", "无论 spike 结果都要建"): 1,
}


def load_registry():
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.stderr.write("roadmap_lint: PyYAML missing (pip install pyyaml)\n")
        sys.exit(2)
    with open(REGISTRY, encoding="utf-8") as f:
        return yaml.safe_load(f)


def main() -> int:
    errors = []
    data = load_registry()
    items = data.get("items", [])

    # 1. unique ids
    ids = [it["id"] for it in items]
    seen = set()
    for i in ids:
        if i in seen:
            errors.append(f"duplicate id: {i}")
        seen.add(i)
    idset = set(ids)

    # 2. prerequisites exist; activation references resolve to ids
    for it in items:
        for p in it.get("hard_prerequisites", []) or []:
            if p not in idset:
                errors.append(f"{it['id']}: unknown prerequisite {p}")
        for a in it.get("activation", []) or []:
            base = re.split(r"[.\s]", a)[0]
            if base and base not in idset and not base.startswith("BASE-G0"):
                errors.append(f"{it['id']}: activation references unknown item {a}")

    # 3. DAG acyclic (hard_prerequisites)
    graph = {it["id"]: list(it.get("hard_prerequisites", []) or []) for it in items}
    WHITE, GREY, BLACK = 0, 1, 2
    color = {k: WHITE for k in graph}

    def dfs(node, stack):
        color[node] = GREY
        for nxt in graph.get(node, []):
            if nxt not in color:
                continue
            if color[nxt] == GREY:
                errors.append(f"dependency cycle: {' -> '.join(stack + [node, nxt])}")
            elif color[nxt] == WHITE:
                dfs(nxt, stack + [node])
        color[node] = BLACK

    for k in graph:
        if color[k] == WHITE:
            dfs(k, [])

    # 4. state consistency
    done = {it["id"] for it in items if it.get("state") == "done"}
    for it in items:
        state = it.get("state")
        prereqs = it.get("hard_prerequisites", []) or []
        unmet = [p for p in prereqs if p not in done]
        if state in ("now", "ready") and unmet:
            errors.append(f"{it['id']}: state={state} but unmet prerequisites {unmet}")
        if state == "blocked" and not unmet and not it.get("activation"):
            errors.append(f"{it['id']}: state=blocked but all prerequisites met and no activation")
        if state == "gated" and not it.get("activation"):
            errors.append(f"{it['id']}: state=gated but no activation condition")

    # 5. gates referenced by activations must exist as gate-typed items
    gate_ids = {it["id"] for it in items if it.get("type") == "gate"}
    for it in items:
        for a in it.get("activation", []) or []:
            base = re.split(r"[.\s]", a)[0]
            if base.startswith("G1-") and base not in gate_ids:
                errors.append(f"{it['id']}: activation gate {base} has no gate card")

    # 6. spikes carry an acceptance policy
    for it in items:
        if it.get("type") == "spike" and not it.get("acceptance_policy"):
            errors.append(f"{it['id']}: spike without acceptance_policy")

    # 7. authority present and file exists
    for it in items:
        auth = it.get("authority")
        if not auth or not auth.get("file"):
            errors.append(f"{it['id']}: missing authority")
        elif not os.path.exists(os.path.join(ROOT, auth["file"])):
            errors.append(f"{it['id']}: authority file missing: {auth['file']}")

    # 8. registry ids appear in roadmap.md; roadmap ID-like tokens exist in registry
    with open(ROADMAP, encoding="utf-8") as f:
        roadmap_text = f.read()
    for i in idset:
        if i not in roadmap_text:
            errors.append(f"{i}: not mentioned in roadmap.md")
    for tok in set(re.findall(r"\b(?:BASE|G1|PERF|GC|SER|HR|FN|DBG|PROC|RT|BACKEND)-[A-Z0-9]+(?:-[A-Z0-9]+)*\b", roadmap_text)):
        if tok not in idset and tok not in ("BASE-G0",):
            errors.append(f"roadmap.md references unknown id: {tok}")

    # 9. forbidden retired phrases
    for rel in SCAN_DOCS:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8").read()
        for phrase in FORBIDDEN_PHRASES:
            count = text.count(phrase)
            allowed = ALLOWLIST.get((rel, phrase), 0)
            if count > allowed:
                errors.append(f"{rel}: retired phrase '{phrase}' appears {count}x (allowed {allowed})")

    if errors:
        for e in errors:
            print(f"FAIL {e}")
        print(f"roadmap-lint: {len(errors)} error(s)")
        return 1
    print(f"roadmap-lint: OK ({len(items)} items)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
