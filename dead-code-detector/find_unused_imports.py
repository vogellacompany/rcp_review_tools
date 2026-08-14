#!/usr/bin/env python3
"""Find unused imports in a Java source tree.

Usage:
    python3 find_unused_imports.py <root> [options]
    python3 find_unused_imports.py <root> --fix

An import is reported as unused when the imported simple name does not occur
in code outside the import statement. Imports referenced only from comments
or Javadoc are reported separately (JAVADOC_ONLY), because a Javadoc
{@link} still needs the import and Eclipse keeps it by default.

With --fix the unused imports are removed from the files.
"""

import argparse
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from functools import partial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import java_analysis as ja


def analyze_file(filepath, ignore_javadoc):
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            raw = f.read()
    except OSError:
        return []
    clean = ja.strip_comments_protect_strings(raw)
    pkg = ja.extract_package(clean)
    imports = ja.extract_imports(clean)
    usage = ja.mask_strings(ja.strip_imports_and_package(clean))
    raw_no_imports = re.sub(
        r'^\s*import\s+(?:static\s+)?[\w.$*]+\s*;.*$', '', raw, flags=re.MULTILINE)
    string_contents = [m.group(0) for m in re.finditer(r'"(?:[^"\\]|\\.)*"', clean)]

    results = []
    for imp in imports:
        if '*' in imp['fqn']:
            continue
        # Only direct java.lang.* classes are implicitly imported, not subpackages like java.lang.reflect
        if not imp['static'] and imp['declaring'] == 'java.lang':
            continue
        simple = imp['member']
        word = r'\b' + re.escape(simple) + r'\b'
        in_code = bool(re.search(word, usage))
        if in_code:
            continue
        in_strings = any(re.search(word, s) for s in string_contents)
        if in_strings:
            continue
        in_raw = bool(re.search(word, raw_no_imports))
        same_pkg = bool(pkg and imp['declaring'] == pkg)
        if in_raw and not ignore_javadoc:
            reason = 'JAVADOC_ONLY'
        else:
            reason = 'UNUSED' if not in_raw else 'UNUSED_IGNORING_JAVADOC'
        if same_pkg:
            reason += '_SAME_PACKAGE'
        results.append((imp, reason))
    return results


def _scan(filepath, ignore_javadoc):
    return filepath, analyze_file(filepath, ignore_javadoc)


def fix_file(filepath, removals):
    with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()
    if '\ufffd' in content:
        print(f"WARN\t{filepath}\tnot a clean UTF-8 file, left unchanged", file=sys.stderr)
        return 0
    lines = content.split('\n')

    first_import = None
    last_import = None
    for idx, line in enumerate(lines):
        if re.match(r'^\s*import\s+', line):
            if first_import is None:
                first_import = idx
            last_import = idx

    if first_import is None:
        return 0

    removed = set()
    import_block_lines = []

    for line in lines[first_import:last_import + 1]:
        hit = False
        for fqn in removals:
            if fqn in removed:
                continue
            if re.match(r'^\s*import\s+(?:static\s+)?' + re.escape(fqn) + r'\s*;', line):
                removed.add(fqn)
                hit = True
                break
        if not hit:
            import_block_lines.append(line)

    # Collapse consecutive empty lines ONLY in the import block
    cleaned_import_lines = []
    prev_empty = False
    for line in import_block_lines:
        if line.strip() == '':
            if not prev_empty:
                cleaned_import_lines.append(line)
            prev_empty = True
        else:
            cleaned_import_lines.append(line)
            prev_empty = False

    # Remove leading/trailing blank lines in import block if all imports gone
    while cleaned_import_lines and cleaned_import_lines[0].strip() == '':
        cleaned_import_lines.pop(0)
    while cleaned_import_lines and cleaned_import_lines[-1].strip() == '':
        cleaned_import_lines.pop()

    out = lines[:first_import] + cleaned_import_lines + lines[last_import + 1:]

    with open(filepath, 'w', encoding='utf-8', errors='replace') as f:
        f.write('\n'.join(out))
    return len(removed)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # Every import is judged inside its own file, so --ignore-test-refs would
    # have nothing to act on and is deliberately not offered.
    ja.add_common_args(ap, 'imports', test_refs=False)
    ap.add_argument('--ignore-javadoc', action='store_true',
                    help='treat imports referenced only from Javadoc as unused')
    ap.add_argument('--fix', action='store_true',
                    help='remove the unused imports from the files')
    args = ap.parse_args()

    exclusions = ja.DEFAULT_EXCLUDE + args.exclude
    paths = [p for p in ja.walk_files(args.roots, exclusions)
             if not (args.skip_tests and ja.is_test_source(p))
             and not (args.internal_only and not ja.is_internal(p))]

    jobs = ja.resolve_jobs(args.jobs)
    if jobs > 1 and len(paths) >= 200:
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            scanned = pool.map(partial(_scan, ignore_javadoc=args.ignore_javadoc),
                               paths, chunksize=max(1, len(paths) // (jobs * 8)))
            scanned = list(scanned)
    else:
        scanned = [_scan(p, args.ignore_javadoc) for p in paths]

    unused = []
    imports_removed = 0
    files_fixed = 0
    for filepath, results in scanned:
        to_remove = [imp['fqn'] for imp, reason in results
                     if reason.startswith('UNUSED')]
        if not to_remove:
            continue
        unused.append((filepath, results))
        if args.fix:
            removed = fix_file(filepath, to_remove)
            imports_removed += removed
            files_fixed += 1 if removed else 0

    print(f"Files with unused imports: {len(unused)}", file=sys.stderr)
    if args.fix:
        print(f"Files fixed: {files_fixed} ({imports_removed} imports removed)",
              file=sys.stderr)

    rows = []
    for filepath, results in sorted(unused):
        for imp, reason in results:
            kind = 'STATIC' if imp['static'] else 'CLASS'
            area = 'INTERNAL' if ja.is_internal(filepath) else 'EXTERNAL_API'
            rows.append((filepath, imp['line'], imp['fqn'], kind, area, reason))

    headers = ['File', 'Line', 'Import', 'Kind', 'Area', 'Reason']
    return ja.emit(rows, headers, "UNUSED_IMPORT", args)


if __name__ == '__main__':
    sys.exit(main())
