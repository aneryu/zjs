#!/usr/bin/env python3
"""Render roadmap.md's generated sections from docs/roadmap/work-items.yaml.

  python3 tools/docs/render_roadmap.py --check   # fail if sections differ
  python3 tools/docs/render_roadmap.py --write   # rewrite sections in place
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REGISTRY = os.path.join(ROOT, "docs", "roadmap", "work-items.yaml")
ROADMAP = os.path.join(ROOT, "docs", "roadmap.md")

GROUPS = [
    ("治理", ("BASE-",)),
    ("gates", ("G1-", "G2-", "BACKEND-")),
    ("性能", ("PERF-",)),
    ("GC", ("GC-", "VM-CONTRACT",)),
    ("序列化", ("SER-",)),
    ("fun 面", ("HR-", "FN-", "DBG-")),
    ("运行时/进程", ("RT-", "PROC-", "VM-WEAK",)),
]


def load():
    import yaml  # type: ignore
    with open(REGISTRY, encoding="utf-8") as f:
        return yaml.safe_load(f)


def group_of(item_id):
    for name, prefixes in GROUPS:
        if any(item_id.startswith(p) for p in prefixes):
            return name
    return "其他"


def fmt_activation(act):
    if not act:
        return ""
    mode = "any" if "any" in act else "all"
    parts = []
    for e in act[mode]:
        c = e["item"]
        if "verdict" in e:
            c += f"={e['verdict']}"
        elif "verdict_not" in e:
            c += f"≠{e['verdict_not']}"
        elif "state" in e:
            c += f".{e['state']}"
        if "condition" in e:
            c += f"[{e['condition']}]"
        parts.append(c)
    joiner = " | " if mode == "any" else " & "
    return joiner.join(parts)


def render_id_list(items):
    lines = ["```"]
    for name, _ in GROUPS:
        ids = [it["id"] for it in items if group_of(it["id"]) == name]
        if not ids:
            continue
        lines.append(f"{name:<8} " + " ".join(ids))
    lines.append("```")
    return "\n".join(lines)


def render_dag(items):
    lines = ["```", "# hard dependencies (A + B -> C); gate conditions listed as activation"]
    for it in items:
        prereqs = it.get("hard_prerequisites") or []
        if prereqs:
            lines.append(f"{' + '.join(prereqs)} -> {it['id']}")
    lines.append("")
    lines.append("# activation conditions (non-DAG unlocks)")
    for it in items:
        act = fmt_activation(it.get("activation"))
        if act:
            lines.append(f"{it['id']}: {act}")
    lines.append("```")
    return "\n".join(lines)


def render_status(items):
    order = ["now", "ready", "gated", "blocked", "later", "incubator", "done"]
    lines = ["```"]
    for st in order:
        ids = [it["id"] for it in items if it.get("state") == st]
        if ids:
            lines.append(f"{st:<10} " + " ".join(ids))
    lines.append("```")
    return "\n".join(lines)


def replace_section(text, name, body):
    begin = f"<!-- BEGIN GENERATED: {name} -->"
    end = f"<!-- END GENERATED: {name} -->"
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
    if not pattern.search(text):
        raise SystemExit(f"render_roadmap: marker pair for {name} missing in roadmap.md")
    return pattern.sub(begin + "\n" + body + "\n" + end, text)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--check"
    data = load()
    items = data["items"]
    with open(ROADMAP, encoding="utf-8") as f:
        text = f.read()
    new = text
    new = replace_section(new, "ID-LIST", render_id_list(items))
    new = replace_section(new, "DAG", render_dag(items))
    new = replace_section(new, "STATUS", render_status(items))
    if mode == "--write":
        if new != text:
            with open(ROADMAP, "w", encoding="utf-8") as f:
                f.write(new)
            print("render_roadmap: sections rewritten")
        else:
            print("render_roadmap: already up to date")
        return 0
    if new != text:
        print("render_roadmap: generated sections out of date (run --write)")
        return 1
    print("render_roadmap: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
