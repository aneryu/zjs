#!/usr/bin/env python3
"""Check live source declarations against inventory and Markdown headings.

Coverage is structural, not a verdict on explanation correctness. Run from the
repository root. File + exact declaration line + name distinguishes same-named
methods in different containers; fenced examples and prose never count.
"""
from __future__ import annotations

import argparse
import csv
import glob
import re
import sys
from pathlib import Path

FUNCTION = re.compile(
    r'^[ \t]*(?P<modifiers>(?:(?:pub|export|extern|inline|noinline)\s+)*)'
    r'fn\s+(?P<name>\w+)\s*\(', re.MULTILINE
)
HEADING = re.compile(r'^#{3,6}\s+`([^`]+)`\s+\(`([^`]+):(\d+)`\)\s*$')
FILE_HEADING = re.compile(r'^#{1,6}\s+(?:\d+\.\s+)?`([^`]+\.zig)`.*$')


def source_functions(path: Path) -> list[tuple[int, str, str, str]]:
    """Scan named implementations; extern declarations are documented as ABI.

    Comments and strings cannot supply fake function declarations. Test coverage
    is not required, but the historical inventory also retains test helpers.
    """
    source = path.read_text(encoding='utf-8')
    ignored = re.compile(r'''//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^'\\\n])'|\\\\[^\n]*''')
    source = ignored.sub(lambda m: re.sub(r'[^\n]', ' ', m[0]), source)
    if re.search(r'\bfn\s+@', source):
        raise ValueError(f'escaped function names need explicit scanner support: {path}')
    result = []
    for match in FUNCTION.finditer(source):
        modifiers = match['modifiers'].split()
        if 'extern' in modifiers:
            continue
        line = source.count('\n', 0, match.start('name')) + 1
        visibility = 'pub' if 'pub' in modifiers else 'priv'
        inline = next((m for m in modifiers if m in ('inline', 'noinline')), '')
        result.append((line, match['name'], visibility, inline))
    return result


def source_name(value: str) -> str:
    return Path(value).resolve().relative_to(Path.cwd().resolve()).as_posix()


def document_headings(paths: list[str]) -> tuple[set[tuple[str, int, str]], set[str]]:
    functions, files = set(), set()
    for path in paths:
        fence = None
        for line in Path(path).read_text(encoding='utf-8').splitlines():
            marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
            if marker:
                if fence is None:
                    fence = marker[1]
                elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                    fence = None
                continue
            if fence is not None:
                continue
            match = HEADING.fullmatch(line)
            if match:
                name, file, number = match.groups()
                functions.add((source_name(file), int(number), name.split('.')[-1]))
            match = FILE_HEADING.fullmatch(line)
            if match:
                files.add(source_name(match[1]))
    return functions, files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--docs', required=True, help='glob of markdown files')
    parser.add_argument('--inventory', default='docs/code-walkthrough/_inventory.tsv')
    parser.add_argument('files', nargs='+', help='existing source files to cover')
    args = parser.parse_args()
    try:
        wanted = {source_name(value) for value in args.files}
        inventory: dict[str, set[tuple[int, str]]] = {}
        with open(args.inventory, encoding='utf-8', newline='') as stream:
            reader = csv.DictReader(stream, delimiter='\t')
            if reader.fieldnames != ['file', 'line', 'vis', 'inline', 'name']:
                raise ValueError('invalid inventory header')
            for row in reader:
                file = source_name(row['file'])
                identity = (int(row['line']), row['name'])
                entries = inventory.setdefault(file, set())
                if identity in entries:
                    raise ValueError(f'duplicate inventory entry: {file}:{identity[0]} {identity[1]}')
                entries.add(identity)
        declarations = {}
        for file in sorted(wanted):
            path = Path(file)
            if not path.is_file() or path.suffix != '.zig':
                raise ValueError(f'unknown Zig source file: {file}')
            actual = {(line, name) for line, name, _, _ in source_functions(path)}
            recorded = inventory.get(file, set())
            if actual != recorded:
                added, stale = sorted(actual - recorded), sorted(recorded - actual)
                raise ValueError(f'inventory differs from source: {file}; unlisted={added}; stale={stale}')
            declarations[file] = actual
        docs = sorted(glob.glob(args.docs))
        if not docs:
            raise ValueError(f'no docs matched {args.docs}')
        headings, file_headings = document_headings(docs)
        missing = []
        for file, entries in sorted(declarations.items()):
            if not entries and file not in file_headings:
                missing.append(f'{file}: missing file heading for zero-function source')
            for line, name in sorted(entries):
                if (file, line, name) not in headings:
                    missing.append(f'{file}:{line} {name}')
        print(f'docs {len(docs)} inventory {sum(map(len, declarations.values()))} missing {len(missing)}')
        for item in missing:
            print(item)
        return 1 if missing else 0
    except (OSError, ValueError, KeyError, TypeError, csv.Error) as error:
        print(f'coverage error: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
