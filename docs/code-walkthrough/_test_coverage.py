#!/usr/bin/env python3
"""Regression cases for structural walkthrough coverage; no engine build."""
import csv
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).with_name('_check_coverage.py').resolve()


class CoverageTests(unittest.TestCase):
    def setUp(self):
        scratch = CHECKER.parents[2] / '.scratch'
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='coverage-test-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'src').mkdir()
        self.write('src/a.zig', 'const A = struct {\n    fn index() void {}\n};\nconst B = struct {\n    fn index() void {}\n};\n')
        self.write('src/b.zig', 'fn index() void {}\n')
        self.inventory([('src/a.zig', 2, 'priv', '', 'index'), ('src/a.zig', 5, 'priv', '', 'index'), ('src/b.zig', 1, 'priv', '', 'index')])
        self.write('doc.md', '### `A.index` (`src/a.zig:2`)\n\n### `B.index` (`src/a.zig:5`)\n')

    def write(self, path, text):
        (self.root / path).write_text(text)

    def inventory(self, rows):
        with (self.root / 'inventory.tsv').open('w', newline='') as stream:
            writer = csv.writer(stream, delimiter='\t')
            writer.writerow(['file', 'line', 'vis', 'inline', 'name'])
            writer.writerows(rows)

    def check(self, *files):
        return subprocess.run([sys.executable, str(CHECKER), '--inventory', 'inventory.tsv', '--docs', 'doc.md', *files], cwd=self.root, text=True, capture_output=True)

    def test_real_headings_cover_distinct_methods(self):
        self.assertEqual(self.check('src/a.zig').returncode, 0)

    def test_same_name_in_wrong_file_is_not_coverage(self):
        result = self.check('src/b.zig')
        self.assertEqual(result.returncode, 1)
        self.assertIn('src/b.zig:1 index', result.stdout)

    def test_one_method_does_not_cover_other_method(self):
        self.write('doc.md', '### `A.index` (`src/a.zig:2`)\n')
        self.assertIn('src/a.zig:5 index', self.check('src/a.zig').stdout)

    def test_prose_and_fenced_headings_are_not_coverage(self):
        self.write('doc.md', '`index`\n```md\n### `index` (`src/b.zig:1`)\n```\n')
        self.assertEqual(self.check('src/b.zig').returncode, 1)

    def test_unknown_selection_is_error_even_with_valid_selection(self):
        result = self.check('src/a.zig', 'src/does-not-exist.zig')
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown Zig source', result.stderr)

    def test_new_file_missing_from_inventory_is_error(self):
        self.write('src/new.zig', 'fn fresh() void {}\n')
        self.assertEqual(self.check('src/new.zig').returncode, 2)

    def test_stale_inventory_is_error(self):
        self.write('src/b.zig', '\nfn index() void {}\n')
        self.assertEqual(self.check('src/b.zig').returncode, 2)

    def test_multiline_declaration_cannot_pass_as_zero_functions(self):
        self.write('src/new.zig', 'fn\nfresh() void {}\n')
        self.write('doc.md', '## `src/new.zig`\n')
        self.assertEqual(self.check('src/new.zig').returncode, 2)

    def test_unsupported_escaped_name_fails_closed(self):
        self.write('src/new.zig', 'fn @"escaped-name"() void {}\n')
        self.write('doc.md', '## `src/new.zig`\n')
        result = self.check('src/new.zig')
        self.assertEqual(result.returncode, 2)
        self.assertIn('escaped function names', result.stderr)

    def test_zero_function_file_needs_file_heading(self):
        self.write('src/types.zig', 'pub const E = error{Oops};\n')
        self.assertEqual(self.check('src/types.zig').returncode, 1)
        self.write('doc.md', '## `src/types.zig`（类型）\n解释 error set。\n')
        self.assertEqual(self.check('src/types.zig').returncode, 0)

    def test_literals_and_comments_do_not_invent_implementations(self):
        self.write('src/types.zig', '''// fn commented() void {}
const quote = '\"';
const text =
    \\\\fn stringOnly() void {}
;
extern "c" fn external() void;
''')
        self.write('doc.md', '## `src/types.zig`\n')
        self.assertEqual(self.check('src/types.zig').returncode, 0)

    def test_bad_inventory_is_not_a_pass(self):
        self.write('inventory.tsv', 'file\twrong\n')
        self.assertEqual(self.check('src/a.zig').returncode, 2)


if __name__ == '__main__':
    unittest.main()
