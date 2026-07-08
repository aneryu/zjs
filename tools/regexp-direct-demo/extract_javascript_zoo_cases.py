#!/usr/bin/env python3
"""Extract direct libregexp cases from the JavaScript Zoo RegExp benchmark.

This is intentionally a static extractor. It reproduces the deterministic
Octane RNG used by bench/regexp.js, then records every Exec(re, string) call
site as pattern/flags/input data. No JavaScript engine is used to produce the
case fixture.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DEFAULT_SOURCE = Path("../javascript-zoo/bench/regexp.js")
DEFAULT_OUTPUT = Path("tests/fixtures/javascript-zoo-regexp/bench/regexp-direct-cases.tsv")


class ExtractError(Exception):
    pass


class OctaneRng:
    def __init__(self) -> None:
        self.seed = 49734321

    def random(self) -> float:
        seed = self.seed
        seed = ((seed + 0x7ED55D16) + (seed << 12)) & 0xFFFFFFFF
        seed = ((seed ^ 0xC761C23C) ^ (seed >> 19)) & 0xFFFFFFFF
        seed = ((seed + 0x165667B1) + (seed << 5)) & 0xFFFFFFFF
        seed = ((seed + 0xD3A2646C) ^ (seed << 9)) & 0xFFFFFFFF
        seed = ((seed + 0xFD7046C5) + (seed << 3)) & 0xFFFFFFFF
        seed = ((seed ^ 0xB55A4F09) ^ (seed >> 16)) & 0xFFFFFFFF
        self.seed = seed
        return (seed & 0x0FFFFFFF) / 0x10000000


def js_units(value: str) -> list[int]:
    raw = value.encode("utf-16-le", "surrogatepass")
    return [raw[i] | (raw[i + 1] << 8) for i in range(0, len(raw), 2)]


def units_to_js_string(units: list[int]) -> str:
    raw = bytearray()
    for unit in units:
        raw.append(unit & 0xFF)
        raw.append((unit >> 8) & 0xFF)
    return bytes(raw).decode("utf-16-le", "surrogatepass")


def compute_input_variants(rng: OctaneRng, value: str, count: int) -> list[str]:
    variants = [value]
    base_units = js_units(value)
    for _ in range(1, count):
        units = list(base_units)
        pos = int(rng.random() * len(units))
        unit = (units[pos] + int(rng.random() * 128)) % 128
        units[pos] = unit
        variants.append(units_to_js_string(units))
    return variants


def decode_js_string(literal: str) -> str:
    if len(literal) < 2 or literal[0] not in ("'", '"') or literal[-1] != literal[0]:
        raise ExtractError(f"invalid string literal: {literal[:80]}")
    quote = literal[0]
    units: list[int] = []
    i = 1
    end = len(literal) - 1
    while i < end:
        ch = literal[i]
        if ch != "\\":
            units.extend(js_units(ch))
            i += 1
            continue

        i += 1
        if i >= end:
            raise ExtractError("unterminated string escape")
        esc = literal[i]
        i += 1
        simple = {
            "b": 0x08,
            "f": 0x0C,
            "n": 0x0A,
            "r": 0x0D,
            "t": 0x09,
            "v": 0x0B,
            "0": 0x00,
        }
        if esc in simple and not (esc == "0" and i < end and literal[i].isdigit()):
            units.append(simple[esc])
        elif esc == "x":
            units.append(int(literal[i : i + 2], 16))
            i += 2
        elif esc == "u":
            if i < end and literal[i] == "{":
                close = literal.index("}", i + 1, end)
                cp = int(literal[i + 1 : close], 16)
                units.extend(js_units(chr(cp)))
                i = close + 1
            else:
                units.append(int(literal[i : i + 4], 16))
                i += 4
        elif esc in ("\n", "\r"):
            if esc == "\r" and i < end and literal[i] == "\n":
                i += 1
        elif esc in ("'", '"', "\\"):
            units.append(ord(esc))
        elif esc in "01234567":
            digits = esc
            while len(digits) < 3 and i < end and literal[i] in "01234567":
                digits += literal[i]
                i += 1
            units.append(int(digits, 8))
        else:
            units.extend(js_units(esc))
    if literal[-1] != quote:
        raise ExtractError("mismatched string quote")
    return units_to_js_string(units)


def parse_js_string_at(text: str, pos: int) -> tuple[str, int]:
    quote = text[pos]
    if quote not in ("'", '"'):
        raise ExtractError(f"expected string at offset {pos}")
    i = pos + 1
    escaped = False
    while i < len(text):
        ch = text[i]
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == quote:
            return text[pos : i + 1], i + 1
        i += 1
    raise ExtractError(f"unterminated string at offset {pos}")


def parse_regex_literal_at(text: str, pos: int) -> tuple[str, str, int]:
    if pos >= len(text) or text[pos] != "/":
        raise ExtractError(f"expected regexp literal at offset {pos}")
    i = pos + 1
    escaped = False
    in_class = False
    body: list[str] = []
    while i < len(text):
        ch = text[i]
        if escaped:
            body.append(ch)
            escaped = False
        elif ch == "\\":
            body.append(ch)
            escaped = True
        elif ch == "[":
            body.append(ch)
            in_class = True
        elif ch == "]":
            body.append(ch)
            in_class = False
        elif ch == "/" and not in_class:
            i += 1
            flags_start = i
            while i < len(text) and (text[i].isalpha() or text[i].isdigit()):
                i += 1
            return "".join(body), text[flags_start:i], i
        else:
            body.append(ch)
        i += 1
    raise ExtractError(f"unterminated regexp literal at offset {pos}")


def split_top_level_args(text: str) -> list[str]:
    args: list[str] = []
    start = 0
    i = 0
    depth = 0
    string_quote: str | None = None
    escaped = False
    regex = False
    regex_class = False
    while i < len(text):
        ch = text[i]
        if string_quote is not None:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == string_quote:
                string_quote = None
            i += 1
            continue
        if regex:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "[":
                regex_class = True
            elif ch == "]":
                regex_class = False
            elif ch == "/" and not regex_class:
                regex = False
            i += 1
            continue
        if ch in ("'", '"'):
            string_quote = ch
            i += 1
            continue
        if ch == "/" and text[start:i].strip() == "":
            regex = True
            i += 1
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:i].strip())
            start = i + 1
        i += 1
    args.append(text[start:].strip())
    return args


def find_matching_paren(text: str, open_pos: int) -> int:
    i = open_pos + 1
    depth = 1
    string_quote: str | None = None
    escaped = False
    regex = False
    regex_class = False
    while i < len(text):
        ch = text[i]
        if string_quote is not None:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == string_quote:
                string_quote = None
            i += 1
            continue
        if regex:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "[":
                regex_class = True
            elif ch == "]":
                regex_class = False
            elif ch == "/" and not regex_class:
                regex = False
            i += 1
            continue
        if ch in ("'", '"'):
            string_quote = ch
        elif ch == "/" and text[open_pos + 1 : i].strip() == "":
            regex = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ExtractError(f"unterminated argument list at offset {open_pos}")


def parse_declarations(text: str) -> tuple[dict[str, tuple[str, str]], dict[str, str], dict[str, list[str]]]:
    regexps: dict[str, tuple[str, str]] = {}
    strings: dict[str, str] = {}
    variants: dict[str, list[str]] = {}
    rng = OctaneRng()
    declaration_re = re.compile(r"\bvar\s+((?:re|str|s)\d+)\s*=\s*")

    for match in declaration_re.finditer(text):
        line_start = text.rfind("\n", 0, match.start()) + 1
        if text[line_start : match.start()].strip().startswith("//"):
            continue
        name = match.group(1)
        pos = match.end()
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if name.startswith("re"):
            pattern, flags, _ = parse_regex_literal_at(text, pos)
            regexps[name] = (pattern, flags)
        elif name.startswith("str"):
            literal, _ = parse_js_string_at(text, pos)
            strings[name] = decode_js_string(literal)
        else:
            prefix = "computeInputVariants("
            if not text.startswith(prefix, pos):
                continue
            open_pos = pos + len(prefix) - 1
            close_pos = find_matching_paren(text, open_pos)
            args = split_top_level_args(text[open_pos + 1 : close_pos])
            if len(args) != 2:
                raise ExtractError(f"bad computeInputVariants args for {name}")
            source_expr = args[0]
            if source_expr.startswith(("'", '"')):
                source = decode_js_string(source_expr)
            else:
                try:
                    source = strings[source_expr]
                except KeyError as exc:
                    raise ExtractError(f"unknown string variable {source_expr}") from exc
            variants[name] = compute_input_variants(rng, source, int(args[1], 10))

    return regexps, strings, variants


def resolve_regex(expr: str, regexps: dict[str, tuple[str, str]]) -> tuple[str, str]:
    expr = expr.strip()
    if expr in regexps:
        return regexps[expr]
    if expr.startswith("/"):
        pattern, flags, end = parse_regex_literal_at(expr, 0)
        if expr[end:].strip():
            raise ExtractError(f"unexpected regexp suffix: {expr[end:]}")
        return pattern, flags
    raise ExtractError(f"unsupported regexp expression: {expr}")


def resolve_input(expr: str, strings: dict[str, str], variants: dict[str, list[str]]) -> str:
    expr = expr.strip()
    if expr.startswith(("'", '"')):
        return decode_js_string(expr)
    if expr in strings:
        return strings[expr]
    match = re.fullmatch(r"(s\d+)\[(.+)\]", expr)
    if match:
        name, index_expr = match.groups()
        index_expr = index_expr.strip()
        if index_expr == "i":
            index = 0
        else:
            plus_match = re.fullmatch(r"(?:i\s*\+\s*(\d+)|(\d+)\s*\+\s*i|(\d+))", index_expr)
            if not plus_match:
                raise ExtractError(f"unsupported variant index expression: {expr}")
            index = int(next(group for group in plus_match.groups() if group is not None), 10)
        try:
            return variants[name][index]
        except KeyError as exc:
            raise ExtractError(f"unknown variant variable {name}") from exc
        except IndexError as exc:
            raise ExtractError(f"variant index out of range: {expr}") from exc
    raise ExtractError(f"unsupported input expression: {expr}")


def encode_pattern(pattern: str) -> str:
    return pattern.encode("utf-8", "surrogatepass").hex()


def encode_input(value: str) -> tuple[str, str]:
    units = js_units(value)
    if all(unit <= 0xFF for unit in units):
        return "latin1", bytes(units).hex()
    raw = bytearray()
    for unit in units:
        raw.append(unit & 0xFF)
        raw.append((unit >> 8) & 0xFF)
    return "utf16le", bytes(raw).hex()


def extract_cases(text: str) -> list[tuple[str, str, str, str, str]]:
    regexps, strings, variants = parse_declarations(text)
    cases: list[tuple[str, str, str, str, str]] = []
    pos = 0
    sequence = 0
    while True:
        pos = text.find("Exec(", pos)
        if pos == -1:
            break
        if text[max(0, pos - 12) : pos].endswith("function "):
            pos += len("Exec(")
            continue
        open_pos = pos + len("Exec")
        close_pos = find_matching_paren(text, open_pos)
        args = split_top_level_args(text[open_pos + 1 : close_pos])
        if len(args) != 2:
            raise ExtractError(f"bad Exec args at offset {pos}")
        pattern, flags = resolve_regex(args[0], regexps)
        input_value = resolve_input(args[1], strings, variants)
        input_kind, input_hex = encode_input(input_value)
        line = text.count("\n", 0, pos) + 1
        sequence += 1
        name = f"regexp_js_line_{line:04d}_{sequence:03d}"
        cases.append((name, flags, encode_pattern(pattern), input_kind, input_hex))
        pos = close_pos + 1
    return cases


def write_cases(path: Path, source: Path, cases: list[tuple[str, str, str, str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as output:
        output.write("# Generated from JavaScript Zoo bench/regexp.js\n")
        output.write(f"# source={source}\n")
        output.write("# columns=name<TAB>flags<TAB>pattern_hex<TAB>input_kind<TAB>input_hex\n")
        for case in cases:
            output.write("\t".join(case))
            output.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    text = args.source.read_text(encoding="utf-8")
    cases = extract_cases(text)
    write_cases(args.output, args.source, cases)
    utf16_count = sum(1 for case in cases if case[3] == "utf16le")
    print(
        f"wrote {len(cases)} direct regexp cases to {args.output} "
        f"(utf16={utf16_count})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
