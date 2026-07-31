#!/usr/bin/env python3
"""Contract tests for the normalized symbol-disassembly comparator.

These run against synthesized objdump text rather than real binaries so the
four required properties are exercised exactly, with no dependency on a
particular toolchain's codegen.
"""

from __future__ import annotations

import importlib.util
import hashlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parent.parent / "compare_symbol_disassembly.py"
_spec = importlib.util.spec_from_file_location("csd", MODULE_PATH)
csd = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(csd)


def disassembly(lines: list[str]) -> list[str]:
    return ["", "a.out:     file format elf64-littleaarch64", ""] + lines


def symbol(name: str, base: int, instructions: list[tuple[str, str]]) -> list[str]:
    """Render one symbol; instructions are (encoding, text) pairs."""
    out = [f"{base:016x} <{name}>:"]
    for index, (encoding, text) in enumerate(instructions):
        out.append(f"  {base + index * 4:x}:\t{encoding} \t{text}")
    return out


def identity_of(lines: list[str]) -> dict:
    bodies = csd.parse_disassembly(disassembly(lines))
    symbols = {
        name: {
            "present": True,
            "size": len(body) * 4,
            "instruction_count": len(body),
            "normalized_body_sha256": csd.hashlib.sha256(
                "\n".join(body).encode()
            ).hexdigest(),
        }
        for name, body in bodies.items()
    }
    return {
        "symbols": symbols,
        "global_normalized_signature": csd.global_signature(symbols),
    }


def write_macho64(path: Path, text: bytes) -> None:
    """Write the smallest thin Mach-O needed to exercise section extraction."""
    header_format = "<IiiIIIII"
    segment_format = "<II16sQQQQiiII"
    section_format = "<16s16sQQIIIIIIII"
    command_size = struct.calcsize(segment_format) + struct.calcsize(section_format)
    text_offset = struct.calcsize(header_format) + command_size
    file_size = text_offset + len(text)
    header = struct.pack(
        header_format,
        0xFEEDFACF,
        0x0100000C,
        0,
        2,
        1,
        command_size,
        0,
        0,
    )
    segment = struct.pack(
        segment_format,
        csd.LC_SEGMENT_64,
        command_size,
        b"__TEXT",
        0x100000000,
        file_size,
        0,
        file_size,
        5,
        5,
        1,
        0,
    )
    section = struct.pack(
        section_format,
        b"__text",
        b"__TEXT",
        0x100000000 + text_offset,
        len(text),
        text_offset,
        2,
        0,
        0,
        0x80000400,
        0,
        0,
        0,
    )
    path.write_bytes(header + segment + section + text)


class ComparatorContract(unittest.TestCase):
    def test_base_address_shift_alone_is_identical(self) -> None:
        """Property 1: relocating a symbol must not count as a code change."""
        low = symbol("hot", 0x400000, [
            ("d10043ff", "sub\tsp, sp, #0x10"),
            ("94000010", "bl\t400100 <callee>"),
            ("54000060", "b.eq\t400018 <hot+0x18>"),
            ("d65f03c0", "ret"),
        ])
        high = symbol("hot", 0x900000, [
            ("d10043ff", "sub\tsp, sp, #0x10"),
            ("94000010", "bl\t900100 <callee>"),
            ("54000060", "b.eq\t900018 <hot+0x18>"),
            ("d65f03c0", "ret"),
        ])
        result = csd.compare(identity_of(low), identity_of(high))
        self.assertTrue(result["identical"], result)
        self.assertEqual(result["body_changed_symbols"], [])

    def test_changed_immediate_is_a_difference(self) -> None:
        """Property 2: immediates carry semantics and must survive normalization."""
        before = symbol("hot", 0x400000, [("d10043ff", "sub\tsp, sp, #0x10")])
        after = symbol("hot", 0x400000, [("d10083ff", "sub\tsp, sp, #0x20")])
        result = csd.compare(identity_of(before), identity_of(after))
        self.assertFalse(result["identical"], result)
        self.assertEqual(result["body_changed_symbols"], ["hot"])
        # Same instruction count -- proving count alone would have missed it.
        self.assertEqual(result["instruction_count_changed_symbols"], [])

    def test_changed_branch_target_is_a_difference(self) -> None:
        """Property 3: the callee identity must not be erased with the address."""
        before = symbol("hot", 0x400000, [("94000010", "bl\t400100 <alpha>")])
        after = symbol("hot", 0x400000, [("94000010", "bl\t400100 <beta>")])
        result = csd.compare(identity_of(before), identity_of(after))
        self.assertFalse(result["identical"], result)
        self.assertEqual(result["body_changed_symbols"], ["hot"])

    def test_symbolless_branch_distance_is_preserved(self) -> None:
        """A bare intra-function branch keeps its distance, not just its shape."""
        near = symbol("hot", 0x400000, [
            ("54000060", "b.eq\t400008"),
            ("d503201f", "nop"),
            ("d65f03c0", "ret"),
        ])
        far = symbol("hot", 0x400000, [
            ("54000060", "b.eq\t400020"),
            ("d503201f", "nop"),
            ("d65f03c0", "ret"),
        ])
        result = csd.compare(identity_of(near), identity_of(far))
        self.assertFalse(result["identical"], result)

    def test_added_and_removed_symbols_are_differences(self) -> None:
        """Property 4: symbol presence is part of the identity."""
        one = symbol("hot", 0x400000, [("d65f03c0", "ret")])
        two = one + symbol("extra", 0x400100, [("d65f03c0", "ret")])
        added = csd.compare(identity_of(one), identity_of(two))
        self.assertFalse(added["identical"], added)
        self.assertEqual(added["added_symbols"], ["extra"])
        removed = csd.compare(identity_of(two), identity_of(one))
        self.assertFalse(removed["identical"], removed)
        self.assertEqual(removed["removed_symbols"], ["extra"])

    def test_unrecognized_line_fails_closed(self) -> None:
        """A line we cannot parse must abort rather than be skipped silently."""
        with self.assertRaises(csd.ParseError):
            csd.parse_disassembly(
                disassembly(["0000000000400000 <hot>:", "  this is not disassembly"])
            )

    def test_empty_disassembly_fails_closed_in_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "empty"
            write_macho64(binary, b"\x00\x00\x00\x00")
            empty = subprocess_result(
                ["objdump"], "\nempty:\tfile format mach-o arm64\n"
            )
            with mock.patch.object(csd.subprocess, "run", return_value=empty):
                with self.assertRaisesRegex(
                    csd.ParseError, "disassembly produced no symbols"
                ):
                    csd.identity(binary)

    def test_macho_text_hash_reads_section_without_objcopy(self) -> None:
        text = bytes.fromhex("f85fbca9c0035fd6")
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "thin-macho"
            write_macho64(binary, text)
            with mock.patch.object(
                csd.subprocess,
                "run",
                side_effect=AssertionError("Mach-O must not invoke objcopy"),
            ):
                self.assertEqual(
                    csd.text_sha256(binary),
                    hashlib.sha256(text).hexdigest(),
                )

    def test_elf_text_hash_keeps_objcopy_failure_strict(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "elf"
            binary.write_bytes(csd.ELF_MAGIC + b"\x00" * 32)
            with mock.patch.object(
                csd.subprocess,
                "run",
                side_effect=FileNotFoundError("objcopy unavailable"),
            ):
                with self.assertRaises(FileNotFoundError):
                    csd.text_sha256(binary)

    def test_macho_identity_requests_native_text_section(self) -> None:
        text = bytes.fromhex("c0035fd6")
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "thin-macho"
            write_macho64(binary, text)
            objdump = subprocess_result(
                ["objdump"],
                "\n"
                f"{binary}:\tfile format mach-o arm64\n"
                "\nDisassembly of section __TEXT,__text:\n\n"
                "00000001000000b8 <_hot>:\n"
                "1000000b8: d65f03c0    \tret\n",
            )
            def run(command: list[str], **_: object) -> object:
                if command[0] == "objdump":
                    self.assertIn("--section=__text", command)
                    return objdump
                raise AssertionError(command)

            with mock.patch.object(csd.subprocess, "run", side_effect=run):
                result = csd.identity(binary)
            self.assertEqual(set(result["symbols"]), {"_hot"})
            self.assertEqual(result["symbols"]["_hot"]["size"], 4)
            self.assertEqual(
                result["text_sha256"], hashlib.sha256(text).hexdigest()
            )

    def test_global_signature_tracks_body_and_size(self) -> None:
        base = identity_of(symbol("hot", 0x400000, [("d65f03c0", "ret")]))
        same = identity_of(symbol("hot", 0x900000, [("d65f03c0", "ret")]))
        other = identity_of(symbol("hot", 0x400000, [("d503201f", "nop")]))
        self.assertEqual(
            base["global_normalized_signature"],
            same["global_normalized_signature"],
        )
        self.assertNotEqual(
            base["global_normalized_signature"],
            other["global_normalized_signature"],
        )


def subprocess_result(command: list[str], stdout: str) -> object:
    return csd.subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")


if __name__ == "__main__":
    unittest.main(verbosity=2)
