#!/usr/bin/env python3
"""Roadmap governance linter (schema v2).

Validates docs/roadmap/work-items.yaml and its consistency with docs/roadmap.md
and the domain docs; also checks the generated sections via render_roadmap.
Run from the repository root:  python3 tools/docs/roadmap_lint.py
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY = os.path.join(ROOT, "docs", "roadmap", "work-items.yaml")
ROADMAP = os.path.join(ROOT, "docs", "roadmap.md")

TYPES = {"governance", "gate", "spike", "spec", "implementation", "measurement"}
STATES = {"now", "ready", "gated", "blocked", "later", "incubator", "done"}
WIP_SLOTS = {"decision", "implementation", "measurement", "none"}
WIP_LIMITS = {"decision": 1, "implementation": 2, "measurement": 1}

FORBIDDEN_PHRASES = [
    "与 Phase 0 并行",
    "批准立即执行",
    "同一 emitter 的两种驱动",
    "一次设计,两期交付",
    "一次设计，两期交付",
    "并发 receive LIFO",
    "无论 spike 结果都要建",
    "挂 G1-JIT 之后",
]
SCAN_DOCS = [
    "docs/roadmap.md",
    "docs/engine-evolution-plan.md",
    "docs/type-directed-optimization-plan.md",
    "docs/fun-native-plugin-design.md",
    "docs/fun-dev-hot-reload-design.md",
    "docs/process-model-design.md",
]
# Pinned counts for legitimate historical citations (ledger/review notes).
ALLOWLIST = {
    ("docs/engine-evolution-plan.md", "批准立即执行"): 1,  # current Phase 0 statement
    ("docs/type-directed-optimization-plan.md", "同一 emitter 的两种驱动"): 1,  # 1.0 note
    ("docs/type-directed-optimization-plan.md", "无论 spike 结果都要建"): 1,  # 1.0 note
}


def load_registry():
    try:
        import yaml  # type: ignore
    except ImportError:
        sys.stderr.write("roadmap_lint: PyYAML missing (pip install pyyaml)\n")
        sys.exit(2)
    with open(REGISTRY, encoding="utf-8") as f:
        return yaml.safe_load(f)


def check_activation(it, idset, by_id, errors):
    act = it.get("activation")
    if act is None:
        return
    if not isinstance(act, dict) or set(act) - {"any", "all"} or len(act) != 1:
        errors.append(f"{it['id']}: activation must be {{any|all: [...]}}")
        return
    mode = next(iter(act))
    for e in act[mode]:
        if not isinstance(e, dict) or "item" not in e:
            errors.append(f"{it['id']}: activation entry missing 'item'")
            continue
        tgt = e["item"]
        if tgt not in idset:
            errors.append(f"{it['id']}: activation references unknown item {tgt}")
            continue
        verdict = e.get("verdict") or e.get("verdict_not")
        if verdict is not None:
            tgt_item = by_id[tgt]
            if tgt_item.get("type") != "gate":
                errors.append(f"{it['id']}: verdict condition on non-gate {tgt}")
            elif verdict not in (tgt_item.get("verdicts") or []):
                errors.append(f"{it['id']}: verdict '{verdict}' not declared by gate {tgt}")
        if "state" in e and e["state"] not in STATES:
            errors.append(f"{it['id']}: activation state '{e['state']}' invalid")


def main() -> int:
    errors = []
    data = load_registry()

    if data.get("schema_version") != 2:
        errors.append("schema_version must be 2")
    with open(ROADMAP, encoding="utf-8") as f:
        roadmap_text = f.read()
    m = re.search(r"版本:(\d+\.\d+)", roadmap_text)
    if m and data.get("roadmap_version") != m.group(1):
        errors.append(f"roadmap_version {data.get('roadmap_version')} != roadmap.md header {m.group(1)}")
    if data.get("roadmap_status") not in ("candidate", "approved"):
        errors.append("roadmap_status must be candidate|approved")

    items = data.get("items", [])
    ids = [it["id"] for it in items]
    seen = set()
    for i in ids:
        if i in seen:
            errors.append(f"duplicate id: {i}")
        seen.add(i)
    idset = set(ids)
    by_id = {it["id"]: it for it in items}

    base_g0_done = by_id.get("BASE-G0", {}).get("state") == "done"

    for it in items:
        iid = it["id"]
        if it.get("type") not in TYPES:
            errors.append(f"{iid}: invalid type {it.get('type')}")
        if it.get("state") not in STATES:
            errors.append(f"{iid}: invalid state {it.get('state')}")
        if it.get("wip_slot") not in WIP_SLOTS:
            errors.append(f"{iid}: invalid wip_slot {it.get('wip_slot')}")
        if it.get("type") == "gate" and not it.get("verdicts"):
            errors.append(f"{iid}: gate without declared verdicts")
        for p in it.get("hard_prerequisites", []) or []:
            if p not in idset:
                errors.append(f"{iid}: unknown prerequisite {p}")
        check_activation(it, idset, by_id, errors)
        auth = it.get("authority")
        if not auth or not auth.get("file"):
            errors.append(f"{iid}: missing authority")
        elif not os.path.exists(os.path.join(ROOT, auth["file"])):
            errors.append(f"{iid}: authority file missing: {auth['file']}")
        if it.get("type") == "spike":
            pol = it.get("acceptance_policy")
            if not pol:
                errors.append(f"{iid}: spike without acceptance_policy")
            elif base_g0_done:
                path = os.path.join(ROOT, pol.get("path", ""))
                if pol.get("status") != "frozen" or not os.path.exists(path):
                    errors.append(f"{iid}: BASE-G0 done but spike policy not frozen/present")
            if it.get("state") == "now" and (it.get("acceptance_policy") or {}).get("status") != "frozen":
                errors.append(f"{iid}: spike in 'now' without a frozen policy")

    # DAG acyclic
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

    # state consistency
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

    # WIP accounting over `now`
    counts = {"decision": 0, "implementation": 0, "measurement": 0}
    for it in items:
        if it.get("state") == "now" and it.get("wip_slot") in counts:
            counts[it["wip_slot"]] += 1
    for slot, limit in WIP_LIMITS.items():
        if counts[slot] > limit:
            errors.append(f"WIP exceeded: {slot} = {counts[slot]} > {limit}")

    # bidirectional id references
    for i in idset:
        if i not in roadmap_text:
            errors.append(f"{i}: not mentioned in roadmap.md")
    for tok in set(re.findall(r"\b(?:BASE|G1|G2|PERF|GC|SER|HR|FN|DBG|PROC|RT|VM|BACKEND)-[A-Z0-9]+(?:-[A-Z0-9]+)*\b", roadmap_text)):
        if tok not in idset:
            errors.append(f"roadmap.md references unknown id: {tok}")

    # retired phrases
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

    # generated sections must match the registry
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "docs", "render_roadmap.py"), "--check"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        errors.append(f"generated sections stale: {r.stdout.strip() or r.stderr.strip()}")

    if errors:
        for e in errors:
            print(f"FAIL {e}")
        print(f"roadmap-lint: {len(errors)} error(s)")
        return 1
    print(f"roadmap-lint: OK ({len(items)} items)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
