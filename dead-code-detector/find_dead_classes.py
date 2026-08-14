#!/usr/bin/env python3
"""Find dead Java classes in a source tree.

Usage:
    python3 find_dead_classes.py <root> [extra_roots ...] [options]

Pass extra roots (for example the other Eclipse platform repositories) so
that a class used from another repository is not reported as dead.

A top-level class is reported as dead when nothing outside its declaring file
refers to it in production code (or anywhere if --ignore-test-refs is not set).
An inner class is reported as dead when it is neither referenced externally
nor used inside its enclosing class.

Results are candidates for review, not a proof that a class is unused.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import java_analysis as ja


def is_inner_class_used(clean, c):
    """Check if an inner class is used within its declaring file.
    
    An inner class is used if:
    1. It is referenced outside its own body span (e.g. in the enclosing class as new Inner(), field type, etc.)
    2. Or it is explicitly instantiated via new Inner() inside its own body (e.g. static factory/recursive helper).
    """
    inner_name = c['name']
    body_start = c.get('body_start', 0)
    body_end = c.get('body_end', len(clean))

    # 1. References outside its own body span
    outside = clean[:body_start] + ' ' + clean[body_end:]
    if re.search(r'\b' + re.escape(inner_name) + r'\b', outside):
        return True

    # 2. Instantiations inside its own body (e.g. factory method)
    inside = clean[body_start:body_end]
    if re.search(r'\bnew\s+' + re.escape(inner_name) + r'\b', inside):
        return True

    return False


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='The first root is the tree to clean; extra roots are scanned '
               'for references (e.g. other repositories).')
    ja.add_common_args(ap, 'classes')
    ap.add_argument('--min-confidence', choices=['all', 'high'], default='all',
                    help='only report HIGH confidence hits (default: all)')
    args = ap.parse_args()

    exclusions = ja.DEFAULT_EXCLUDE + args.exclude
    index = ja.ClassIndex(args.roots, exclusions, jobs=args.jobs)
    if not index.class_by_fqn:
        print('No Java classes found.', file=sys.stderr)
        sys.exit(0)

    refs_by_file = {}
    for filepath in index.files:
        refs_by_file[filepath] = index.count_refs(filepath)

    non_java_refs = ja.count_non_java_classes(index, args.roots, exclusions)

    dead = []
    for fqn, c in index.class_by_fqn.items():
        decl_file = c['file']

        prod_ext_refs = non_java_refs.get(fqn, 0)
        test_ext_refs = 0

        for filepath, f_refs in refs_by_file.items():
            if filepath != decl_file:
                cnt = f_refs.get(fqn, 0)
                if cnt > 0:
                    if ja.is_test_source(filepath):
                        test_ext_refs += cnt
                    else:
                        prod_ext_refs += cnt

        # Determine if dead in production / overall
        if prod_ext_refs > 0:
            continue

        if test_ext_refs > 0 and not args.ignore_test_refs:
            continue

        usage = 'TEST_ONLY' if test_ext_refs > 0 else 'UNUSED'

        # If top-level and no production external references -> candidate
        if c['top_level']:
            simple = c['name']
            collides = (len(index.top_by_simple.get(simple, [])) > 1
                        or len(index.nested_by_name.get(simple, [])) > 0)
            confidence = 'VERIFY' if collides else 'HIGH'
            dead.append((c, confidence, usage))
        else:
            # Inner class: check if used internally in the declaring file
            clean = index.meta[decl_file]['clean']
            if not is_inner_class_used(clean, c):
                simple = c['name']
                collides = (len(index.top_by_simple.get(simple, [])) > 0
                            or len(index.nested_by_name.get(simple, [])) > 1)
                confidence = 'VERIFY' if collides else 'HIGH'
                dead.append((c, confidence, usage))

    print(f"Total classes: {len(index.class_by_fqn)}", file=sys.stderr)
    print(f"Dead candidates: {len(dead)}", file=sys.stderr)

    target_root = os.path.abspath(args.roots[0])
    rows = []
    for c, conf, usage in sorted(dead, key=lambda x: x[0]['fqn']):
        filepath = c['file']
        if not os.path.abspath(filepath).startswith(target_root):
            continue
        if args.internal_only and not ja.is_internal(filepath):
            continue
        if args.skip_tests and ja.is_test_source(filepath):
            continue
        if args.min_confidence == 'high' and conf != 'HIGH':
            continue
        kind = 'TOPLEVEL' if c['top_level'] else 'INNER'
        area = 'INTERNAL' if ja.is_internal(filepath) else 'EXTERNAL_API'
        src = 'TEST' if ja.is_test_source(filepath) else 'CODE'
        rows.append((filepath, c['name'], kind, area, conf, src, usage))

    headers = ['File', 'Class', 'Kind', 'Area', 'Confidence', 'Source', 'Usage']
    return ja.emit(rows, headers, "DEAD_CLASS", args)


if __name__ == '__main__':
    sys.exit(main())
