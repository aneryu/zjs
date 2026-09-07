#!/usr/bin/env python3
"""Freeze and compare Linux ELF size/source evidence; never a performance gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import struct
import subprocess
import sys
import time

SCHEMA = 1
SOURCE_SUFFIXES = {'.zig', '.c', '.h', '.cpp', '.hpp', '.py', '.js', '.ts', '.sh'}
CATEGORIES = ('engine', 'generated', 'tests', 'build', 'tools', 'other_source')
GENERATED = {'src/libs/unicode/data.zig', 'src/abi/fun_native_abi.h'}


def run(argv, cwd=None, timeout=1200):
    return subprocess.check_output(argv, cwd=cwd, timeout=timeout, stderr=subprocess.PIPE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def category(path):
    if path in GENERATED:
        return 'generated'
    if path.startswith(('src/tests/', 'tests/')) or Path(path).name.endswith('_tests.zig') or path in ('src/compiler/tests.zig', 'src/compiler/test_entry.zig'):
        return 'tests'
    if path.startswith('src/'):
        return 'engine'
    if path.startswith('build/') or path in ('build.zig', 'build.zig.zon'):
        return 'build'
    if path.startswith('tools/'):
        return 'tools'
    return 'other_source'


def inventory(repo):
    """All tracked and nonignored untracked content; submodule identity is explicit."""
    files = []
    gitlinks = {}
    for record in run(['git', 'ls-files', '--stage', '-z'], repo).decode().split('\0'):
        if record.startswith('160000 '):
            metadata, name = record.split('\t', 1)
            gitlinks[name] = metadata.split()[1]
    totals = {name: {'files': 0, 'physical_lines': 0, 'bytes': 0} for name in CATEGORIES}
    names = sorted(set(run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], repo).decode().split('\0')) - {''})
    for name in names:
        path = repo / name
        if not path.exists() and not path.is_symlink():
            files.append({'path': name, 'deleted': True})
            continue
        if name in gitlinks:
            initialized = path.is_dir() and (path / '.git').exists()
            files.append({'path': name, 'kind': 'submodule', 'index_revision': gitlinks[name],
                          'revision': run(['git', 'rev-parse', 'HEAD'], path).decode().strip() if initialized else None,
                          'status': run(['git', 'status', '--porcelain', '--untracked-files=all'], path).decode() if initialized else 'uninitialized'})
            continue
        if path.is_dir():
            raise ValueError(f'Unsupported directory source entry: {name}')
        data = path.read_bytes() if path.exists() else b''
        entry = {'path': name, 'sha256': digest(data), 'bytes': len(data),
                 'executable': bool(path.stat().st_mode & 0o111) if path.exists() else False}
        if path.is_symlink():
            entry['symlink'] = os.readlink(path)
        if path.suffix in SOURCE_SUFFIXES or name == 'build.zig.zon':
            entry['category'] = category(name)
            entry['physical_lines'] = len(data.splitlines())
            total = totals[entry['category']]
            total['files'] += 1
            total['bytes'] += len(data)
            total['physical_lines'] += entry['physical_lines']
        files.append(entry)
    return {'revision': run(['git', 'rev-parse', 'HEAD'], repo).decode().strip(),
            'status': run(['git', 'status', '--porcelain', '--untracked-files=all'], repo).decode(),
            'content_sha256': digest(encoded(files)), 'files': files, 'totals': totals,
            'line_rule': 'Physical lines including comments/blanks/generated code; no semantic LOC claim. Submodule contents excluded.'}


def elf_sections(path):
    """Use binutils for section flags, including opcode islands and NOBITS."""
    data = path.read_bytes()
    header = data[:64]
    if platform.system() != 'Linux' or header[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Only Linux little-endian ELF64 artifacts are supported')
    target = {'elf_class': 64, 'endian': 'little', 'machine': struct.unpack_from('<H', header, 18)[0]}
    sections = []
    # readelf -W prevents line wrapping. Blank flags are legitimate.
    pattern = re.compile(r'^\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s*(.*?)\s+\d+\s+\d+\s+\d+\s*$')
    for line in run(['readelf', '-W', '-S', str(path)]).decode().splitlines():
        match = pattern.match(line)
        if not match:
            continue
        name, kind, address, offset, size, flags = match.groups()
        size = int(size, 16)
        sections.append({'name': name, 'type': kind, 'flags': flags.strip(),
                         'memory_bytes': size, 'disk_bytes': 0 if kind == 'NOBITS' else size,
                         'address': int(address, 16),
                         'sha256': None if kind == 'NOBITS' else digest(data[int(offset, 16):int(offset, 16) + size])})
    if not sections or not any('X' in s['flags'] for s in sections):
        raise ValueError('ELF section table has no executable sections')
    disk = sum(s['disk_bytes'] for s in sections)
    return {'target': target, 'sections': sections, 'file_bytes': path.stat().st_size,
            'section_disk_bytes': disk,
            'headers_padding_other_bytes': path.stat().st_size - disk,
            'executable_section_bytes': sum(s['disk_bytes'] for s in sections if 'X' in s['flags']),
            'nobits_memory_bytes': sum(s['memory_bytes'] for s in sections if s['type'] == 'NOBITS')}


def seal(out, binary, source, provenance, expected_mode):
    original = out / 'binary'
    shutil.copyfile(binary, original)
    original.chmod(0o755)
    config = run([str(original), '--print-config-signature'], timeout=30).decode().strip()
    if not re.fullmatch(r'zjs-config-v\d+:[^\s]+', config):
        raise ValueError('Artifact did not print exactly one zjs configuration signature')
    if f'optimize={expected_mode}' not in config.split(':', 1)[1].split(','):
        raise ValueError('Artifact optimization signature differs from requested build')
    stripped = out / 'binary.stripped'
    shutil.copyfile(original, stripped)
    run(['strip', '--strip-all', str(stripped)])
    stripped.chmod(0o755)
    if run([str(stripped), '--print-config-signature'], timeout=30).decode().strip() != config:
        raise ValueError('Stripped artifact configuration differs from original')
    original_sections, stripped_sections = elf_sections(original), elf_sections(stripped)
    def allocated(report):
        return [(section['name'], section['address'], section['disk_bytes'], section['sha256'])
                for section in report['sections'] if 'A' in section['flags'] and section['type'] != 'NOBITS']
    if allocated(original_sections) != allocated(stripped_sections):
        raise ValueError('Strip changed allocated file-backed section addresses or contents')
    report = {'schema': SCHEMA, 'kind': 'size-source-screen-not-performance-verdict',
              'config': config, 'source': source, 'provenance': provenance,
              'original_sha256': digest(original.read_bytes()),
              'stripped_sha256': digest(stripped.read_bytes()),
              'original_bytes': original.stat().st_size, 'stripped': stripped_sections,
              'strip_validation': 'runtime signature and allocated file-backed addresses/content identical'}
    (out / 'manifest.json').write_bytes(encoded(report))
    (out / 'manifest.sha256').write_text(digest(encoded(report)) + '\n')
    for name in ('binary', 'binary.stripped', 'manifest.json', 'manifest.sha256'):
        (out / name).chmod(0o555 if name.startswith('binary') else 0o444)
    return report


def native_target(build_cpus):
    # Zig 0.16 emits ZON. Preserve its complete native block verbatim rather
    # than losing CPU feature/OS ABI information in an ELF-machine shorthand.
    targets = run(['taskset', '-c', build_cpus, 'zig', 'targets']).decode()
    marker = '\n    .native = .{'
    if targets.count(marker) != 1 or not targets.rstrip().endswith('}'):
        raise ValueError('Could not identify Zig native target block')
    return targets.split(marker, 1)[1].strip()


def stop_build_group(process, timeout_seconds=5):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        # A process stuck in the kernel, or a detached descendant holding a
        # pipe, must not turn cancellation into an unbounded wait.
        return error.output or b'', False
    return output, True


def build_capture(command, repo, out, timeout_seconds=1220):
    process = None
    pending_signal = None

    def cancel(signum, _frame):
        nonlocal pending_signal
        if process is None:
            # Popen may have spawned the child before returning its handle.
            pending_signal = signum
            return
        # Conventional shell cancellation statuses, after group cleanup.
        raise SystemExit(128 + signum)

    old_handlers = {sig: signal.signal(sig, cancel)
                    for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            process = subprocess.Popen(command, cwd=repo, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            if pending_signal is not None:
                raise SystemExit(128 + pending_signal)
            output, _ = process.communicate(timeout=timeout_seconds)
        except BaseException as error:
            # Repeated cancellation must not interrupt reaping/log retention.
            for sig in old_handlers:
                signal.signal(sig, signal.SIG_IGN)
            if process is not None:
                output, cleaned = stop_build_group(process)
                (out / 'build.log').write_bytes(output)
                if not cleaned:
                    print('size-screen: build cleanup incomplete after 5 seconds; '
                          'captured output retained in ' + str(out / 'build.log'), file=sys.stderr)
            if isinstance(error, subprocess.TimeoutExpired):
                raise ValueError('Build process group timed out; see ' + str(out / 'build.log')) from error
            raise
        (out / 'build.log').write_bytes(output)
        return process.returncode, output
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def freeze(args):
    repo = Path(run(['git', 'rev-parse', '--show-toplevel'], args.repo).decode().strip())
    out = Path(args.out).resolve()
    # Reject output under tracked/nonignored paths: it would invalidate source identity.
    try:
        relative = out.relative_to(repo)
    except ValueError:
        relative = None
    if relative is not None:
        ignored = subprocess.run(['git', 'check-ignore', '-q', str(relative)], cwd=repo).returncode == 0
        if not ignored:
            raise ValueError('Snapshot output inside repository must be git-ignored (use .scratch/)')
    out.mkdir(parents=True, exist_ok=False)
    before = inventory(repo)
    native = native_target(args.build_cpus)
    prefix = out / 'build'
    build_step = 'zjs' if args.optimize == 'ReleaseFast' else 'zjs-size'
    command = ['timeout', '--kill-after=5s', '1200', 'flock', '-x', '/tmp/zjs-host-heavy.lock',
               'taskset', '-c', args.build_cpus, 'zig', 'build', build_step,
               '-Doptimize=' + args.optimize, '--prefix', str(prefix), '-j32', '--summary', 'all']
    # Capture the isolated build group with bounded cancellation and diagnostics.
    started = time.monotonic()
    build_exit, output = build_capture(command, repo, out)
    elapsed = time.monotonic() - started
    if build_exit:
        raise ValueError(f'Build failed ({build_exit}); see {out / "build.log"}')
    after = inventory(repo)
    if before != after:
        raise ValueError('Repository content changed during build; discard this snapshot and retry')
    provenance = {'build_command': command, 'build_exit': build_exit, 'build_elapsed_seconds': elapsed, 'build_step': build_step,
                  'native_target': native,
                  'zig_version': run(['zig', 'version'], repo).decode().strip(),
                  'host': platform.machine(), 'build_log_sha256': digest(output),
                  'strip_version': run(['strip', '--version']).decode().splitlines()[0],
                  'readelf_version': run(['readelf', '--version']).decode().splitlines()[0],
                  'source_evidence': 'owned build, identical inventories before and after'}
    report = seal(out, prefix / 'bin' / build_step, before, provenance, args.optimize)
    shutil.rmtree(prefix)
    print(json.dumps({'snapshot': str(out), 'stripped_bytes': report['stripped']['file_bytes'],
                      'source_totals': report['source']['totals']}, indent=2))


def load_snapshot(path):
    path = Path(path)
    raw = (path / 'manifest.json').read_bytes()
    if digest(raw) != (path / 'manifest.sha256').read_text().strip():
        raise ValueError(f'Manifest identity mismatch: {path}')
    report = json.loads(raw)
    if report['schema'] != SCHEMA:
        raise ValueError('Unsupported snapshot schema')
    for name, key in [('binary', 'original_sha256'), ('binary.stripped', 'stripped_sha256'), ('build.log', None)]:
        expected = report[key] if key else report['provenance']['build_log_sha256']
        if digest((path / name).read_bytes()) != expected:
            raise ValueError(f'Frozen file identity mismatch: {path / name}')
    if digest(encoded(report['source']['files'])) != report['source']['content_sha256']:
        raise ValueError('Source inventory identity mismatch')
    return report


def current_mismatches(report, source, optimize, zig_version, target):
    provenance = report['provenance']
    reasons = []
    if provenance.get('build_exit') != 0 or provenance.get('source_evidence') != 'owned build, identical inventories before and after':
        reasons.append('snapshot lacks successful owned-build provenance')
    if source['content_sha256'] != report['source']['content_sha256']:
        reasons.append('repository content differs')
    if any(f.get('kind') == 'submodule' and f.get('status') not in ('', 'uninitialized') for f in source['files']):
        reasons.append('dirty submodule contents are not fully hashed')
    expected_step = 'zjs' if optimize == 'ReleaseFast' else 'zjs-size'
    if provenance.get('build_step') != expected_step or f'optimize={optimize}' not in report['config'].split(':', 1)[1].split(','):
        reasons.append('build mode differs')
    if provenance['zig_version'] != zig_version:
        reasons.append('Zig version differs')
    if provenance['native_target'] != target:
        reasons.append('native target differs')
    return reasons


def verify_current(args):
    """Validate reuse of an existing artifact without rebuilding or resealing it."""
    report = load_snapshot(args.snapshot)
    repo = Path(args.repo).resolve()
    source = inventory(repo)
    reasons = current_mismatches(report, source, args.optimize,
                                 run(['zig', 'version'], repo).decode().strip(),
                                 native_target(args.build_cpus))
    if inventory(repo) != source:
        raise ValueError('Repository changed during verification')
    print(json.dumps({'kind': 'snapshot-reuse-not-new-build-or-test-verdict',
                      'decision': 'REBUILD' if reasons else 'REUSE', 'reasons': reasons,
                      'snapshot': str(Path(args.snapshot).resolve()),
                      'source_sha256': source['content_sha256'],
                      'binary_sha256': report['original_sha256'],
                      'stripped_sha256': report['stripped_sha256']}, indent=2))
    return 3 if reasons else 0


def precheck_source(args):
    """Reject low-value source candidates before paying for an owned build."""
    base = load_snapshot(args.baseline)
    candidate = inventory(Path(args.repo).resolve())
    categories = sorted(set(args.source_category or ['engine']))
    deltas = {name: candidate['totals'][name]['physical_lines'] - base['source']['totals'][name]['physical_lines']
              for name in CATEGORIES}
    saving = -sum(deltas[name] for name in categories)
    passed = saving >= args.min_lines
    print(json.dumps({
        'kind': 'source-precheck-not-build-or-size-verdict',
        'screen': 'CONTINUE' if passed else 'STOP',
        'minimum_saving': args.min_lines,
        'source_categories': categories,
        'source_physical_lines_delta': deltas,
        'baseline_source_sha256': base['source']['content_sha256'],
        'candidate_source_sha256': candidate['content_sha256'],
        'candidate_revision': candidate['revision'],
        'candidate_status': candidate['status'],
        'next_step': 'freeze and compare this source state; then validate behavior' if passed else 'archive or revise candidate; no build needed',
    }, indent=2))
    return 0 if passed else 3


def compare(args):
    base, candidate = load_snapshot(args.baseline), load_snapshot(args.candidate)
    if base['provenance']['native_target'] != candidate['provenance']['native_target']:
        raise ValueError('Native codegen targets differ (CPU/features/OS ABI)')
    if base['stripped']['target'] != candidate['stripped']['target']:
        raise ValueError('ELF targets differ')
    if base['provenance']['zig_version'] != candidate['provenance']['zig_version']:
        raise ValueError('Zig versions differ; freeze a matching baseline')
    if base['provenance']['strip_version'] != candidate['provenance']['strip_version']:
        raise ValueError('Strip versions differ; freeze a matching baseline')
    cross = base['config'] != candidate['config']
    if cross and not args.allow_cross_config:
        raise ValueError('Configurations differ; intentional experiments require --allow-cross-config')
    sections = {}
    for sign, report in [(-1, base), (1, candidate)]:
        for section in report['stripped']['sections']:
            sections[section['name']] = sections.get(section['name'], 0) + sign * section['disk_bytes']
    byte_delta = candidate['stripped']['file_bytes'] - base['stripped']['file_bytes']
    source_categories = args.source_category or ['engine']
    line_delta = sum(candidate['source']['totals'][name]['physical_lines'] - base['source']['totals'][name]['physical_lines'] for name in set(source_categories))
    passed = -byte_delta >= args.min_bytes if args.objective == 'binary' else -line_delta >= args.min_lines
    print(json.dumps({'kind': 'size-source-screen-not-performance-verdict', 'cross_config': cross,
                      'objective': args.objective, 'source_categories': source_categories, 'minimum_saving': args.min_bytes if args.objective == 'binary' else args.min_lines,
                      'screen': 'CONTINUE' if passed else 'STOP',
                      'baseline_config': base['config'], 'candidate_config': candidate['config'],
                      'baseline_identity': {'revision': base['source']['revision'], 'source_sha256': base['source']['content_sha256'], 'binary_sha256': base['original_sha256'], 'manifest_sha256': digest(encoded(base))},
                      'candidate_identity': {'revision': candidate['source']['revision'], 'source_sha256': candidate['source']['content_sha256'], 'binary_sha256': candidate['original_sha256'], 'manifest_sha256': digest(encoded(candidate))},
                      'stripped_bytes_delta': candidate['stripped']['file_bytes'] - base['stripped']['file_bytes'],
                      'executable_bytes_delta': candidate['stripped']['executable_section_bytes'] - base['stripped']['executable_section_bytes'],
                      'section_disk_bytes_delta': sections,
                      'headers_padding_other_bytes_delta': candidate['stripped']['headers_padding_other_bytes'] - base['stripped']['headers_padding_other_bytes'],
                      'source_physical_lines_delta': {name: candidate['source']['totals'][name]['physical_lines'] - base['source']['totals'][name]['physical_lines'] for name in CATEGORIES}}, indent=2))
    return 0 if passed else 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    capture = sub.add_parser('freeze', help='Build and freeze a new source-bound snapshot')
    capture.add_argument('--repo', default='.')
    capture.add_argument('--out', required=True)
    capture.add_argument('--optimize', choices=['ReleaseFast', 'ReleaseSmall'], default='ReleaseFast')
    capture.add_argument('--build-cpus', default=os.environ.get('ZJS_BUILD_CPUS', '5-8,15-18'))
    reuse = sub.add_parser('verify-current', help='Verify an owned snapshot matches current inputs without rebuilding')
    reuse.add_argument('snapshot')
    reuse.add_argument('--repo', default='.')
    reuse.add_argument('--optimize', choices=['ReleaseFast', 'ReleaseSmall'], default='ReleaseFast')
    reuse.add_argument('--build-cpus', default=os.environ.get('ZJS_BUILD_CPUS', '5-8,15-18'))
    precheck = sub.add_parser('precheck-source', help='Screen current source lines without compiling or executing an artifact')
    precheck.add_argument('baseline')
    precheck.add_argument('--repo', default='.')
    precheck.add_argument('--min-lines', required=True, type=int)
    precheck.add_argument('--source-category', action='append', choices=CATEGORIES)
    delta = sub.add_parser('compare')
    delta.add_argument('baseline')
    delta.add_argument('candidate')
    delta.add_argument('--allow-cross-config', action='store_true')
    delta.add_argument('--objective', required=True, choices=['binary', 'source'])
    delta.add_argument('--min-bytes', type=int)
    delta.add_argument('--min-lines', type=int)
    delta.add_argument('--source-category', action='append', choices=CATEGORIES,
                       help='Source objective categories (repeatable; default engine)')
    args = parser.parse_args()
    try:
        if args.command == 'verify-current':
            return verify_current(args)
        if args.command == 'precheck-source':
            if args.min_lines <= 0:
                raise ValueError('--min-lines must be positive')
            return precheck_source(args)
        if args.command == 'compare':
            threshold = args.min_bytes if args.objective == 'binary' else args.min_lines
            extra = args.min_lines if args.objective == 'binary' else args.min_bytes
            if threshold is None or threshold <= 0 or extra is not None:
                raise ValueError('Specify exactly the positive --min-bytes or --min-lines for the selected objective')
        return (freeze if args.command == 'freeze' else compare)(args) or 0
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print(f'size-screen: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
