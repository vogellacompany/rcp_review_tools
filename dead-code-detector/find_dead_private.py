#!/usr/bin/env python3
"""Find dead private methods and fields in a Java source tree.

Usage:
    python3 find_dead_private.py <root> [options]

A private method is reported as dead when it is never called, referenced
with ::, or mentioned in a string literal (e.g. JUnit @MethodSource).
Special serialization methods and framework-injected methods (@Inject, @Execute,
@PostConstruct, etc.) are excluded.

A private field is reported as dead when it appears only in its declarations
and is never read or written elsewhere in the file.
"""

import argparse
import os
import re
import sys
from collections import Counter
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import java_analysis as ja


def analyze_file(filepath):
    """Return the dead private methods and fields of one file as (name, line) pairs."""
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
    except OSError:
        return [], []
    clean = ja.strip_comments_protect_strings(content)
    pkg = ja.extract_package(clean)
    class_names = {c['name'] for c in ja.collect_classes(clean, pkg)}

    dead_methods = []
    methods = ja.find_private_methods_with_lines(clean, class_names)
    method_decl = Counter(name for name, _ in methods)
    if method_decl:
        usages = ja.count_method_usages(clean, method_decl)
        for name, line in methods:
            if usages.get(name, 0) == method_decl[name]:
                dead_methods.append((name, line))

    dead_fields = []
    fields = ja.find_private_fields_with_lines(clean)
    field_decl = Counter(name for name, _ in fields)
    for name, line in fields:
        occ = len(re.findall(r'\b' + re.escape(name) + r'\b', clean))
        if occ == field_decl[name]:
            dead_fields.append((name, line))

    return dead_methods, dead_fields


def _scan(filepath):
    methods, fields = analyze_file(filepath)
    return filepath, methods, fields


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # This detector never looks past the declaring file, so --ignore-test-refs
    # would have nothing to act on and is deliberately not offered.
    ja.add_common_args(ap, 'members', test_refs=False)
    args = ap.parse_args()

    exclusions = ja.DEFAULT_EXCLUDE + args.exclude
    paths = [p for p in ja.walk_files(args.roots, exclusions)
             if not (args.skip_tests and ja.is_test_source(p))
             and not (args.internal_only and not ja.is_internal(p))]

    jobs = ja.resolve_jobs(args.jobs)
    if jobs > 1 and len(paths) >= 200:
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            scanned = list(pool.map(_scan, paths, chunksize=max(1, len(paths) // (jobs * 8))))
    else:
        scanned = [_scan(p) for p in paths]

    rows_methods = []
    rows_fields = []
    for filepath, dead_methods, dead_fields in scanned:
        area = 'INTERNAL' if ja.is_internal(filepath) else 'EXTERNAL_API'
        for name, line in dead_methods:
            rows_methods.append((filepath, line, name, area))
        for name, line in dead_fields:
            rows_fields.append((filepath, line, name, area))

    print(f"Dead private methods: {len(rows_methods)}", file=sys.stderr)
    print(f"Dead private fields: {len(rows_fields)}", file=sys.stderr)

    if args.format in ('json', 'markdown', 'summary'):
        all_rows = [('METHOD',) + r for r in sorted(rows_methods)] + \
                   [('FIELD',) + r for r in sorted(rows_fields)]
        headers = ['Type', 'File', 'Line', 'Member', 'Area']
        return ja.emit(all_rows, headers, "DEAD_PRIVATE", args)

    for filepath, line, name, area in sorted(rows_methods):
        print(f"DEAD_PRIVATE_METHOD\t{filepath}\t{line}\t{name}\t{area}")
    for filepath, line, name, area in sorted(rows_fields):
        print(f"DEAD_PRIVATE_FIELD\t{filepath}\t{line}\t{name}\t{area}")
    return 1 if (rows_methods or rows_fields) and args.fail_on_findings else 0


if __name__ == '__main__':
    sys.exit(main())
