#!/usr/bin/env python3
"""Find dead public/protected static final constants in a Java source tree.

Usage:
    python3 find_dead_constants.py <root> [extra_roots ...] [options]

A constant is reported as dead when nothing outside its declaring file refers
to it in production code (or anywhere if --ignore-test-refs is not set) and
it is not read within its declaring file.
References are resolved through static imports, qualified names (Class.CONST),
unique names, and non-Java configuration files.

Results are candidates for review, not a proof that a constant is unused.
"""

import argparse
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import java_analysis as ja


def build_const_index(index):
    """Group the constants the index already parsed by id and by simple name."""
    const_by_id = {}
    by_simple = defaultdict(list)
    meta = {}
    for filepath in index.files:
        file_meta = index.meta[filepath]
        pkg = file_meta['pkg']
        decl_by_name = defaultdict(int)
        for k in file_meta['constants']:
            if k['id'] not in const_by_id:
                const_by_id[k['id']] = dict(k, file=filepath, pkg=pkg)
            by_simple[k['name']].append(k['id'])
            decl_by_name[k['name']] += 1
        static_members = defaultdict(set)
        for imp in file_meta['imports']:
            if imp['static']:
                static_members[imp['member']].add(imp['declaring'])
        meta[filepath] = {
            'decl_by_name': dict(decl_by_name),
            'static_members': static_members,
        }
    return const_by_id, by_simple, meta


def resolve_const(tok, statics, by_simple, const_by_id):
    """Resolve an unqualified constant token; empty set when ambiguous."""
    stat = statics.get(tok)
    if stat:
        res = set()
        for declaring in stat:
            cid = declaring + '.' + tok
            if cid in const_by_id:
                res.add(cid)
        return res
    ids = by_simple.get(tok)
    if ids and len(ids) == 1:
        return {ids[0]}
    return set()


def count_const_refs(filepath, me, index, const_by_id, by_simple):
    refs = defaultdict(int)
    content = index.count_content(filepath)
    scope = index.scope_for(filepath)
    statics = me['static_members']
    for m in ja.TOKEN_RE.finditer(content):
        tok = m.group(1)
        # No constant is named `tok`, so neither the qualified nor the
        # unqualified lookup below can resolve; skip the expensive scan.
        if tok not in by_simple:
            continue
        owner_m = re.search(r'((?:[A-Za-z_$][\w$]*\.)+)$', content[max(0, m.start() - 120):m.start()])
        if owner_m:
            qualifier = owner_m.group(1).rstrip('.')
            owners = index.resolve_chain(qualifier, scope)
            if not owners:
                owners = index.resolve_token(qualifier, scope)
            if owners:
                for cfqn in owners:
                    cid = cfqn + '.' + tok
                    if cid in const_by_id:
                        refs[cid] += 1
                continue
        if index.resolve_token(tok, scope):
            continue
        for cid in resolve_const(tok, statics, by_simple, const_by_id):
            refs[cid] += 1
    return refs


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='The first root is the tree to clean; extra roots are scanned '
               'for references (e.g. other repositories).')
    ja.add_common_args(ap, 'constants')
    ap.add_argument('--min-confidence', choices=['all', 'high'], default='all',
                    help='only report HIGH confidence hits (default: all)')
    args = ap.parse_args()

    exclusions = ja.DEFAULT_EXCLUDE + args.exclude
    index = ja.ClassIndex(args.roots, exclusions, jobs=args.jobs)
    const_by_id, by_simple, meta = build_const_index(index)
    if not const_by_id:
        print('No constants found.', file=sys.stderr)
        sys.exit(0)

    prod_refs_total = defaultdict(int)
    test_refs_total = defaultdict(int)

    for filepath in meta:
        is_test = ja.is_test_source(filepath)
        for cid, count in count_const_refs(filepath, meta[filepath], index,
                                           const_by_id, by_simple).items():
            if const_by_id[cid]['file'] != filepath:
                if is_test:
                    test_refs_total[cid] += count
                else:
                    prod_refs_total[cid] += count

    # Non-Java references (e.g. XML configs, properties) count as prod_refs
    non_java_refs = ja.count_non_java_constants(const_by_id, by_simple, args.roots, exclusions)
    for cid, count in non_java_refs.items():
        prod_refs_total[cid] += count

    dead = []
    for cid, k in const_by_id.items():
        if prod_refs_total.get(cid, 0) > 0:
            continue
        if test_refs_total.get(cid, 0) > 0 and not args.ignore_test_refs:
            continue

        me = meta[k['file']]
        occ = len(re.findall(r'\b' + re.escape(k['name']) + r'\b',
                             index.count_content(k['file'])))
        decl = me['decl_by_name'].get(k['name'], 0)
        if occ > decl:
            continue

        usage = 'TEST_ONLY' if test_refs_total.get(cid, 0) > 0 else 'UNUSED'
        collides = len(by_simple[k['name']]) > 1
        confidence = 'VERIFY' if collides else 'HIGH'
        dead.append((k, confidence, usage))

    print(f"Total constants: {len(const_by_id)}", file=sys.stderr)
    print(f"Dead candidates: {len(dead)}", file=sys.stderr)

    target_root = os.path.abspath(args.roots[0])
    rows = []
    for k, conf, usage in sorted(dead, key=lambda x: x[0]['id']):
        filepath = k['file']
        if not os.path.abspath(filepath).startswith(target_root):
            continue
        if args.internal_only and not ja.is_internal(filepath):
            continue
        if args.skip_tests and ja.is_test_source(filepath):
            continue
        if args.min_confidence == 'high' and conf != 'HIGH':
            continue
        area = 'INTERNAL' if ja.is_internal(filepath) else 'EXTERNAL_API'
        src = 'TEST' if ja.is_test_source(filepath) else 'CODE'
        rows.append((filepath, k['name'], area, conf, src, usage))

    headers = ['File', 'Constant', 'Area', 'Confidence', 'Source', 'Usage']
    return ja.emit(rows, headers, "DEAD_CONSTANT", args)


if __name__ == '__main__':
    sys.exit(main())
