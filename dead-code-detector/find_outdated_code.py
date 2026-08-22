#!/usr/bin/env python3
"""Find outdated, suspicious and potentially slow code in a Java source tree.

Usage:
    python3 find_outdated_code.py <root> [extra_roots ...] [options]
    python3 find_outdated_code.py --list-rules

Every hit names a rule. OUTDATED rules point at idioms that a newer Java or
Eclipse API replaces, BAD rules at error handling and resource patterns that
hide problems, SLOW rules at code that is usually worth profiling. Comments
and string literals are ignored. Hits are candidates for review: a VERIFY
rule matches a pattern that is sometimes correct as written.
"""

import argparse
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import java_analysis as ja

_SAM_LISTENERS = (
    'Runnable|Callable|Comparator|Supplier|Consumer|BiConsumer|Function|BiFunction|'
    'Predicate|UnaryOperator|BinaryOperator|'
    'Listener|ModifyListener|DisposeListener|PaintListener|VerifyListener|'
    'ArmListener|HelpListener|MenuDetectListener|TraverseListener|'
    'IPropertyChangeListener|IDoubleClickListener|ISelectionChangedListener|'
    'IOpenListener|ICheckStateListener|IJobChangeListener|IResourceChangeListener|'
    'ISafeRunnable|IRunnableWithProgress|ICoreRunnable|IWorkspaceRunnable'
)

# (rule id, category, confidence, regex, message)
RULES = [
    ('boxed-constructor', 'OUTDATED', 'HIGH',
     r'\bnew\s+(?:Integer|Long|Boolean|Double|Float|Short|Byte|Character)\s*\(',
     'Boxed constructors are deprecated for removal; use valueOf or autoboxing'),
    ('legacy-collection', 'OUTDATED', 'HIGH',
     r'\bnew\s+(?:Vector|Hashtable|Stack)\s*[<(]',
     'Vector/Hashtable/Stack are legacy; use ArrayList, HashMap or ArrayDeque'),
    ('stringbuffer', 'OUTDATED', 'VERIFY',
     r'\bnew\s+StringBuffer\s*\(',
     'StringBuffer synchronizes every call; use StringBuilder unless shared across threads'),
    ('anonymous-lambda-candidate', 'OUTDATED', 'HIGH',
     r'\bnew\s+(?:' + _SAM_LISTENERS + r')\s*(?:<[^<>;{]*>)?\s*\(\s*\)\s*\{',
     'Anonymous class of a single-method interface; use a lambda or method reference'),
    ('selection-adapter', 'OUTDATED', 'VERIFY',
     r'\bnew\s+SelectionAdapter\s*\(\s*\)\s*\{',
     'Use SelectionListener.widgetSelectedAdapter(e -> ...) when only one method is overridden'),
    ('thread-runnable', 'OUTDATED', 'HIGH',
     r'\bnew\s+Thread\s*\(\s*new\s+Runnable\s*\(\s*\)\s*\{',
     'new Thread(new Runnable() {...}) can be a lambda'),
    ('iterator-loop', 'OUTDATED', 'VERIFY',
     r'\bfor\s*\(\s*(?:final\s+)?Iterator\s*(?:<[^<>;]*>)?\s+\w+\s*=\s*[\w.()]+\.iterator\(\)\s*;',
     'Explicit iterator loop; use an enhanced for loop unless remove() is needed'),
    ('index-loop-over-list', 'OUTDATED', 'VERIFY',
     r'\bfor\s*\(\s*int\s+(\w+)\s*=\s*0\s*;\s*\1\s*<\s*\w+\.size\(\)\s*;\s*\1\+\+\s*\)',
     'Index loop over a List; use an enhanced for loop unless the index is used'),
    ('instanceof-cast', 'OUTDATED', 'VERIFY',
     r'\b(\w+)\s+instanceof\s+([\w.]+)\s*\)\s*\{?\s*(?:final\s+)?\2\s+\w+\s*=\s*\(\s*\2\s*\)\s*\1\b',
     'instanceof followed by a cast; use pattern matching (Java 16)'),
    ('explicit-generic-args', 'OUTDATED', 'HIGH',
     r'\b\w+\s*<[^<>=;()]+>\s+\w+\s*=\s*new\s+[\w.]+\s*<[^<>=;()]+>\s*\(',
     'Explicit type arguments on the right-hand side; use the diamond operator'),
    ('junit3', 'OUTDATED', 'HIGH',
     r'\bextends\s+(?:junit\.framework\.)?TestCase\b|\bimport\s+junit\.framework\.',
     'JUnit 3 test; migrate to JUnit 5'),
    ('junit4', 'OUTDATED', 'VERIFY',
     r'\bimport\s+(?:static\s+)?org\.junit\.(?:Test|Assert|Before|After|BeforeClass|AfterClass|Rule|Ignore)\b',
     'JUnit 4 API; migrate to JUnit 5 (org.junit.jupiter)'),
    ('line-separator-property', 'OUTDATED', 'HIGH',
     r'System\.getProperty\(\s*"line\.separator"\s*\)',
     'Use System.lineSeparator()'),
    ('class-newinstance', 'OUTDATED', 'HIGH',
     r'\.newInstance\(\s*\)',
     'Class.newInstance() is deprecated; use getDeclaredConstructor().newInstance()'),
    ('finalize', 'OUTDATED', 'HIGH',
     r'\bprotected\s+void\s+finalize\s*\(\s*\)',
     'finalize() is deprecated for removal; use Cleaner or explicit dispose'),
    ('date-gettime', 'OUTDATED', 'HIGH',
     r'\bnew\s+Date\(\s*\)\.getTime\(\)',
     'Use System.currentTimeMillis()'),
    ('legacy-date-api', 'OUTDATED', 'VERIFY',
     r'\bnew\s+(?:SimpleDateFormat|GregorianCalendar)\s*\(|\bCalendar\.getInstance\(',
     'Legacy date API; use java.time'),
    ('size-equals-zero', 'OUTDATED', 'VERIFY',
     r'\.(?:size|length)\(\)\s*(?:==|!=|>|<=)\s*0\b',
     'Use isEmpty()'),
    ('empty-string-equals', 'OUTDATED', 'VERIFY',
     r'""\s*\.equals\s*\(|\.equals\s*\(\s*""\s*\)',
     'Use isEmpty()'),
    ('file-stream', 'OUTDATED', 'VERIFY',
     r'\bnew\s+(?:FileInputStream|FileOutputStream|FileReader|FileWriter)\s*\(',
     'Use java.nio.file.Files (newInputStream, newBufferedReader, ...)'),
    ('toarray-sized', 'OUTDATED', 'VERIFY',
     r'\.toArray\(\s*new\s+[\w.]+\s*\[\s*\w+(?:\(\))?\.size\(\)\s*\]\s*\)',
     'toArray(new T[0]) is simpler and as fast on modern JVMs'),
    ('synchronized-wrapper', 'OUTDATED', 'VERIFY',
     r'\bCollections\.synchronized(?:Map|Set|List)\s*\(',
     'Consider ConcurrentHashMap / CopyOnWriteArrayList'),
    ('empty-catch', 'BAD', 'HIGH',
     r'\bcatch\s*\([^)]*\)\s*\{\s*\}',
     'Empty catch block swallows the exception'),
    ('print-stack-trace', 'BAD', 'HIGH',
     r'\.printStackTrace\(\s*\)',
     'Log through ILog / Platform.getLog instead of printStackTrace'),
    ('system-out', 'BAD', 'VERIFY',
     r'\bSystem\.(?:out|err)\.print(?:ln|f)?\s*\(',
     'Console output in plug-in code; use the platform log'),
    ('catch-throwable', 'BAD', 'VERIFY',
     r'\bcatch\s*\(\s*(?:final\s+)?Throwable\s+\w+\s*\)',
     'Catching Throwable also catches Errors; catch Exception or use SafeRunner'),
    ('mutable-static', 'BAD', 'VERIFY',
     r'\b(?:public|protected)\s+static\s+(?!final\b)(?:[\w.<>,\[\]]+\s+)+\w+\s*(?:=|;)',
     'Mutable non-final static field'),
    ('sync-exec', 'SLOW', 'VERIFY',
     r'\.syncExec\s*\(',
     'syncExec blocks the calling thread; use asyncExec unless the result is needed'),
    ('thread-sleep', 'SLOW', 'VERIFY',
     r'\bThread\.sleep\s*\(',
     'Thread.sleep in product code usually hides a missing wait condition'),
    ('pattern-compile-in-method', 'SLOW', 'VERIFY',
     r'^(?![^\n]*\bstatic\b)[^\n]*\bPattern\.compile\s*\(',
     'Pattern.compile outside a static field recompiles on every call'),
    ('swt-resource-creation', 'SLOW', 'VERIFY',
     r'\bnew\s+(?:Image|Color|Font|Cursor)\s*\(\s*(?:display|Display\.|\w+\.getDisplay\(\)|null|parent)',
     'SWT resource created by hand; prefer JFaceResources or a LocalResourceManager'),
    ('string-concat-in-loop', 'SLOW', 'VERIFY',
     r'\b(?:for|while)\s*\([^)]*\)\s*\{[^{}]*\b(\w+)\s*\+=\s*(?:"|\w+\s*\+\s*")',
     'String concatenation in a loop; use StringBuilder'),
]

_COMPILED = [(rid, cat, conf, re.compile(rx, re.MULTILINE), msg)
             for rid, cat, conf, rx, msg in RULES]

# Bundle-RequiredExecutionEnvironment below this is reported.
MIN_BREE = 17


def scan_text(masked, rules=None):
    """Return (rule id, category, confidence, offset, message) for each hit in masked code."""
    hits = []
    for rid, cat, conf, rx, msg in _COMPILED:
        if rules and rid not in rules:
            continue
        for m in rx.finditer(masked):
            hits.append((rid, cat, conf, m.start(), msg))
    return hits


def analyze_file(filepath, rules=None):
    """Return one (line, rule, category, confidence, message, snippet) per hit in a file."""
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
    except OSError:
        return []
    if filepath.endswith('MANIFEST.MF'):
        return _analyze_manifest(content, rules)
    clean = ja.strip_comments_protect_strings(content)
    masked = ja.mask_strings(clean)
    lines = clean.splitlines()
    rows = []
    for rid, cat, conf, off, msg in scan_text(masked, rules):
        line = ja.line_of(masked, off)
        snippet = lines[line - 1].strip() if 0 < line <= len(lines) else ''
        rows.append((line, rid, cat, conf, msg, snippet[:120]))
    return rows


def _analyze_manifest(content, rules):
    if rules and 'old-bree' not in rules:
        return []
    m = re.search(r'^Bundle-RequiredExecutionEnvironment:\s*JavaSE-(\d+(?:\.\d+)?)', content, re.MULTILINE)
    if not m:
        return []
    # JavaSE-1.8 is Java 8
    version = m.group(1)
    major = int(version.split('.')[1]) if version.startswith('1.') else int(version.split('.')[0])
    if major >= MIN_BREE:
        return []
    line = content[:m.start()].count('\n') + 1
    return [(line, 'old-bree', 'OUTDATED', 'HIGH',
             f'Bundle-RequiredExecutionEnvironment below JavaSE-{MIN_BREE}', m.group(0))]


def _worker(args):
    filepath, rules = args
    return filepath, analyze_file(filepath, rules)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog='The first root is the tree to check; extra roots are accepted '
               'for symmetry with the other detectors and are scanned too.')
    ja.add_common_args(ap, 'hits', test_refs=False)
    ap.add_argument('--min-confidence', choices=['all', 'high'], default='all',
                    help='only report HIGH confidence hits (default: all)')
    ap.add_argument('--category', action='append', choices=['OUTDATED', 'BAD', 'SLOW'],
                    help='only report this category (repeatable)')
    ap.add_argument('--rules', help='comma separated rule ids to run')
    ap.add_argument('--list-rules', action='store_true', help='print the rule table and exit')
    if '--list-rules' in sys.argv:
        for rid, cat, conf, _, msg in RULES:
            print(f'{rid}\t{cat}\t{conf}\t{msg}')
        print(f'old-bree\tOUTDATED\tHIGH\tBundle-RequiredExecutionEnvironment below JavaSE-{MIN_BREE}')
        return 0
    args = ap.parse_args()

    rules = set(args.rules.split(',')) if args.rules else None
    exclusions = ja.DEFAULT_EXCLUDE + args.exclude
    files = list(ja.walk_files(args.roots, exclusions, extensions=('.java', 'MANIFEST.MF')))

    if args.skip_tests:
        files = [f for f in files if not ja.is_test_source(f)]
    if args.internal_only:
        files = [f for f in files if ja.is_internal(f)]

    jobs = ja.resolve_jobs(args.jobs)
    work = [(f, rules) for f in files]
    if jobs > 1 and len(files) > 50:
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(_worker, work, chunksize=32))
    else:
        results = [_worker(w) for w in work]

    rows = []
    for filepath, hits in results:
        area = 'INTERNAL' if ja.is_internal(filepath) else 'EXTERNAL_API'
        src = 'TEST' if ja.is_test_source(filepath) else 'CODE'
        for line, rid, cat, conf, msg, snippet in hits:
            if args.min_confidence == 'high' and conf != 'HIGH':
                continue
            if args.category and cat not in args.category:
                continue
            rows.append((filepath, line, rid, cat, conf, area, src, msg, snippet))
    rows.sort(key=lambda r: (r[0], r[1]))

    print(f'Files scanned: {len(files)}', file=sys.stderr)
    print(f'Hits: {len(rows)}', file=sys.stderr)
    headers = ['File', 'Line', 'Rule', 'Category', 'Confidence', 'Area', 'Source', 'Message', 'Snippet']
    return ja.emit(rows, headers, 'OUTDATED_CODE', args)


if __name__ == '__main__':
    sys.exit(main())
