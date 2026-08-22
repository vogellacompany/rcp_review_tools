#!/usr/bin/env python3
"""Shared helpers for the dead-code detector scripts.

These detectors are name-based heuristics for large Java source trees. They
produce candidates for manual review; finding a symbol is not a proof that
it is unused (reflection, build files outside the scanned roots, and other
repositories can still reference it).
"""

import json
import os
import re
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor

DEFAULT_EXCLUDE = ['.claude', '/target/', '/.git/', '/.settings/', '/bin/', '/node_modules/']

KEYWORDS = frozenset('''
abstract assert boolean break byte case catch char class const continue
default do double else enum extends final finally float for goto if
implements import instanceof int interface long native new package private
protected public return short static strictfp super switch synchronized this
throw throws transient try void volatile while true false null var record
sealed non-sealed permits yield module requires exports opens uses provides with
transitive to non when _
'''.split())

TOKEN_RE = re.compile(r'\b([A-Za-z_$][\w$]*)\b')
CHAIN_RE = re.compile(r'(?<![\w.$])(?:[A-Za-z_$][\w$]*)(?:\.[A-Za-z_$][\w$]*)+')
IMPORT_RE = re.compile(r'^\s*import\s+(static\s+)?([\w.$*]+)\s*;', re.MULTILINE)
TYPE_RE = re.compile(r'(?<![\w.$])(class|@?interface|enum|record)\s+([A-Za-z_$][\w$]*)')

# Match any permutation of (public|protected) + static + final
CONST_MOD_RE = re.compile(
    r'(?<![\w.])(?:'
    r'(?:public|protected)\s+(?:static\s+final|final\s+static)|'
    r'static\s+(?:(?:public|protected)\s+final|final\s+(?:public|protected))|'
    r'final\s+(?:(?:public|protected)\s+static|static\s+(?:public|protected))'
    r')\s+'
)

_TYPE_KEYWORD_RE = re.compile(r'(?:class|@?interface|enum|record)\b')

# Matched against one already isolated statement (see top_level_statements),
# never against a whole interface body: the lazy quantifier spans whitespace,
# so on a large body it degenerated into a quadratic backtrack.
INTERFACE_FIELD_RE = re.compile(
    r'\s*(?:@[\w.$]+(?:\s*\([^)]*\))?\s*)*'
    r'(?:(?:public|protected|static|final)\s+)*'
    r'(?!default\b|void\b|class\b|interface\b|enum\b|record\b|@interface\b)'
    r'([\w$<>,\s?\[\].]+?)\s+'
    r'([A-Za-z_$][\w$]*\s*=[^;]+);\s*\Z'
)

FRAMEWORK_METHOD_ANNOTATIONS = frozenset({
    'Inject', 'Execute', 'CanExecute', 'PostConstruct', 'PreDestroy',
    'AboutToHide', 'AboutToShow', 'Focus', 'Persist', 'Preference',
    'EventHandler', 'FXML', 'Test', 'ParameterizedTest', 'RepeatedTest',
    'TestFactory', 'BeforeEach', 'AfterEach', 'BeforeAll', 'AfterAll',
    'Before', 'After', 'BeforeClass', 'AfterClass', 'Subscribe', 'EventListener'
})

SPECIAL_PRIVATE_METHODS = frozenset({
    'readObject', 'writeObject', 'readResolve', 'writeReplace', 'readObjectNoData'
})

SPECIAL_PRIVATE_FIELDS = frozenset({
    'serialVersionUID', 'serialPersistentFields'
})

GENERIC_CONST_NAMES = frozenset({
    'ID', 'NAME', 'TYPE', 'VALUE', 'KEY', 'TAG', 'DEFAULT', 'NONE', 'ALL',
    'EMPTY', 'TRUE', 'FALSE', 'TEXT', 'URL', 'PATH', 'PREFIX', 'SUFFIX',
    'OK', 'ERROR', 'WARN', 'INFO', 'CANCEL', 'YES', 'NO', 'ICON', 'LABEL',
    'TITLE', 'DESC', 'WIDTH', 'HEIGHT', 'SIZE', 'CLASS', 'INTERFACE'
})

NON_JAVA_EXTENSIONS = (
    '.xml', '.mf', '.properties', '.txt', '.html', '.htm', '.json',
    '.product', '.target', '.launch', '.yml', '.yaml', '.ini', '.md',
    '.adoc', '.xsl', '.xslt', '.js', '.tld', '.css', '.c', '.h',
    '.gradle', '.prefs', '.options', '.preferences', '.tokens',
    '.csv', '.toml', '.jsp', '.exsd'
)


def walk_files(roots, exclusions=DEFAULT_EXCLUDE, extensions=('.java',)):
    """Yield files under roots that match the given extensions."""
    for root in roots:
        if not os.path.exists(root):
            continue
        if os.path.isfile(root):
            if root.endswith(extensions):
                yield os.path.abspath(root)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            norm_dir = dirpath.replace(os.sep, '/') + '/'
            if any(ex in norm_dir or ex.strip('/') in norm_dir.split('/') for ex in exclusions):
                dirnames[:] = []
                continue
            dirnames[:] = [
                d for d in dirnames
                if not any(ex in (norm_dir + d + '/') for ex in exclusions)
            ]
            for fname in filenames:
                if fname.endswith(extensions):
                    yield os.path.join(dirpath, fname)


def strip_comments_protect_strings(code):
    """Remove Java comments while protecting string and char literals."""
    result = []
    i = 0
    n = len(code)
    in_string = False
    in_text_block = False
    in_char = False
    in_line = False
    in_block = False
    while i < n:
        c = code[i]
        next_c = code[i + 1] if i + 1 < n else ''
        if in_line:
            if c == '\n':
                in_line = False
                result.append(c)
            else:
                result.append(' ')
            i += 1
            continue
        if in_block:
            if c == '*' and next_c == '/':
                in_block = False
                result.append('  ')
                i += 2
            else:
                result.append(c if c == '\n' else ' ')
                i += 1
            continue
        if in_text_block:
            if c == '\\' and i + 1 < n:
                result.append(c)
                result.append(code[i + 1])
                i += 2
                continue
            if c == '"' and code[i:i + 3] == '"""':
                in_text_block = False
                result.append('"""')
                i += 3
            else:
                result.append(c)
                i += 1
            continue
        if in_string:
            if c == '\\' and i + 1 < n:
                result.append(c)
                result.append(code[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            result.append(c)
            i += 1
            continue
        if in_char:
            if c == '\\' and i + 1 < n:
                result.append(c)
                result.append(code[i + 1])
                i += 2
                continue
            if c == "'":
                in_char = False
            result.append(c)
            i += 1
            continue
        if c == '/' and next_c == '/':
            in_line = True
            result.append('  ')
            i += 2
            continue
        if c == '/' and next_c == '*':
            in_block = True
            result.append('  ')
            i += 2
            continue
        if c == '"' and code[i:i + 3] == '"""':
            in_text_block = True
            result.append('"""')
            i += 3
            continue
        if c == '"':
            in_string = True
            result.append(c)
            i += 1
            continue
        if c == "'":
            in_char = True
            result.append(c)
            i += 1
            continue
        result.append(c)
        i += 1
    return ''.join(result)


def mask_strings(code):
    """Replace the contents of string/char/text-block literals with spaces."""
    out = []
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        if c == '"' and code[i:i + 3] == '"""':
            out.append('   ')
            i += 3
            while i < n:
                if code[i] == '\\' and i + 1 < n:
                    out.append('  ')
                    i += 2
                    continue
                if code[i:i + 3] == '"""':
                    out.append('   ')
                    i += 3
                    break
                out.append(code[i] if code[i] == '\n' else ' ')
                i += 1
            continue
        if c == '"' or c == "'":
            quote = c
            out.append(' ')
            i += 1
            while i < n:
                c2 = code[i]
                if c2 == '\\':
                    out.append('  ' if (i + 1 < n and code[i + 1] != '\n') else ' ')
                    i += 2
                    continue
                if c2 == quote:
                    out.append(' ')
                    i += 1
                    break
                out.append(c2 if c2 == '\n' else ' ')
                i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def line_of(text, offset):
    """1-based line number of an offset."""
    return text.count('\n', 0, offset) + 1


def extract_package(clean):
    m = re.search(r'^\s*package\s+([\w.$]+)\s*;', clean, re.MULTILINE)
    return m.group(1) if m else ''


def extract_imports(clean):
    imports = []
    for m in IMPORT_RE.finditer(clean):
        is_static = m.group(1) is not None
        full = m.group(2)
        parts = full.rsplit('.', 1)
        imports.append({
            'fqn': full,
            'static': is_static,
            'member': parts[-1],
            'declaring': parts[0] if len(parts) == 2 else '',
            'line': line_of(clean, m.start()),
        })
    return imports


def strip_imports_and_package(clean):
    code = IMPORT_RE.sub('', clean)
    code = re.sub(r'^\s*package\s+[\w.$]+\s*;', '', code, flags=re.MULTILINE)
    return code


def brace_depth_at(code, offsets):
    """Return a dict offset->brace depth for each of the given offsets."""
    res = {}
    if not offsets:
        return res
    offs = sorted(set(offsets))
    depth = 0
    idx = 0
    for i, c in enumerate(code):
        if idx < len(offs) and offs[idx] == i:
            res[i] = depth
            idx += 1
        if c == '{':
            depth += 1
        elif c == '}':
            depth = max(0, depth - 1)
    for o in offs[idx:]:
        res[o] = depth
    return res


def find_matching_brace(code, open_pos):
    """Find matching closing brace for an opening brace at open_pos."""
    depth = 0
    for i in range(open_pos, len(code)):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def collect_classes(clean, pkg, masked=None):
    """Return list of type declarations with their fully-qualified names and body spans."""
    if masked is None:
        masked = mask_strings(clean)
    matches = []
    for m in TYPE_RE.finditer(masked):
        kind = m.group(1)
        name = m.group(2)
        if name in KEYWORDS:
            continue
        body = masked.find('{', m.end())
        if body < 0:
            continue
        body_end = find_matching_brace(masked, body)
        matches.append((kind, name, m.start(), body, body_end))
    if not matches:
        return []
    depths = brace_depth_at(masked, [b for _, _, _, b, _ in matches])
    classes = []
    stack = []
    for kind, name, decl_start, body_start, body_end in matches:
        d = depths[body_start]
        while stack and stack[-1][0] >= d:
            stack.pop()
        parent = stack[-1][1] if stack else None
        if parent:
            fqn = parent + '.' + name
        elif pkg:
            fqn = pkg + '.' + name
        else:
            fqn = name
        classes.append({
            'name': name,
            'fqn': fqn,
            'kind': kind,
            'parent': parent,
            'top_level': parent is None,
            'body_depth': d,
            'decl_start': decl_start,
            'body_start': body_start,
            'body_end': body_end,
            'line': line_of(clean, decl_start),
        })
        stack.append((d, fqn))
    return classes


def _const_names_with_values(segment_clean, segment_masked):
    """Extract (name, string_value_or_none) pairs from a constant declaration segment."""
    results = []
    i = 0
    n = len(segment_masked)
    paren = 0
    angle = 0
    bracket = 0
    brace = 0
    in_value = False
    current_name = None
    value_start = 0

    while i < n:
        c = segment_masked[i]
        if c == '(':
            paren += 1
            i += 1
            continue
        if c == ')':
            paren = max(0, paren - 1)
            i += 1
            continue
        if c == '<':
            angle += 1
            i += 1
            continue
        if c == '>':
            angle = max(0, angle - 1)
            i += 1
            continue
        if c == '[':
            bracket += 1
            i += 1
            continue
        if c == ']':
            bracket = max(0, bracket - 1)
            i += 1
            continue
        if c == '{':
            brace += 1
            i += 1
            continue
        if c == '}':
            brace = max(0, brace - 1)
            i += 1
            continue

        nesting = paren + angle + bracket + brace

        if nesting == 0:
            if c == '=':
                in_value = True
                value_start = i + 1
                i += 1
                continue
            if c == ',' or c == ';':
                if current_name:
                    str_val = None
                    if in_value and value_start < i:
                        val_raw = segment_clean[value_start:i].strip()
                        str_m = re.search(r'^"([^"\\]*(?:\\.[^"\\]*)*)"$', val_raw)
                        if str_m:
                            str_val = str_m.group(1)
                    results.append((current_name, str_val))
                    current_name = None
                in_value = False
                if c == ';':
                    break
                i += 1
                continue

        if not in_value and nesting == 0:
            if c.isalpha() or c == '_' or c == '$':
                m = re.match(r'[A-Za-z_$][\w$]*', segment_masked[i:])
                if m:
                    tok = m.group(0)
                    end = i + m.end()
                    if tok not in KEYWORDS and tok not in ('true', 'false', 'null'):
                        if not (i > 0 and segment_masked[i - 1] in '.;@'):
                            j = end
                            while j < n and segment_masked[j].isspace():
                                j += 1
                            if j < n and segment_masked[j] in '=;,':
                                current_name = tok
                    i = end
                    continue

        i += 1
    return results


def _const_names(segment):
    """Backward compatible name extractor."""
    return [name for name, _ in _const_names_with_values(segment, segment)]


def top_level_statements(masked, start, end):
    """Yield (begin, stop) spans of the `;`-terminated statements directly in a type body.

    Anything nested in parentheses, braces or brackets is skipped, so method
    bodies and initializer blocks do not produce statements of their own.
    """
    depth = 0
    begin = start
    saw_assign = False
    for i in range(start, end):
        c = masked[i]
        if c in '({[':
            depth += 1
        elif c in ')}]':
            if depth > 0:
                depth -= 1
            # A block that is not the right hand side of an assignment is a
            # method body or an initializer, so the next statement starts fresh.
            if depth == 0 and c == '}' and not saw_assign:
                begin = i + 1
        elif depth == 0:
            if c == '=':
                saw_assign = True
            elif c == ';':
                yield begin, i + 1
                begin = i + 1
                saw_assign = False


def _statement_end(masked, start):
    """Offset of the ';' terminating the declaration that starts at start."""
    paren = brace = bracket = 0
    i = start
    n = len(masked)
    while i < n:
        j = masked.find(';', i)
        if j < 0:
            return n
        seg = masked[i:j]
        paren += seg.count('(') - seg.count(')')
        brace += seg.count('{') - seg.count('}')
        bracket += seg.count('[') - seg.count(']')
        if paren <= 0 and brace <= 0 and bracket <= 0:
            return j
        i = j + 1
    return n


def collect_constants(clean, pkg, classes, masked=None):
    """Return public/protected static final constants and interface constants with declaring class."""
    if masked is None:
        masked = mask_strings(clean)
    if not classes:
        return []

    matches = []
    # 1. Explicit public/protected static final in any class/interface
    for m in CONST_MOD_RE.finditer(masked):
        start = m.end()
        # "public static final class Foo implements Bar" is a type, not a field
        if _TYPE_KEYWORD_RE.match(masked, start):
            continue
        i = _statement_end(masked, start)
        if i >= len(masked):
            continue
        segment_clean = clean[start:i + 1]
        segment_masked = masked[start:i + 1]
        pairs = _const_names_with_values(segment_clean, segment_masked)
        if pairs:
            matches.append((m.start(), pairs))

    # 2. Implicit constants in interfaces/annotations (int MAX = 5;)
    for c in classes:
        if c.get('kind') in ('interface', '@interface'):
            for begin, stop in top_level_statements(masked, c['body_start'] + 1, c['body_end']):
                seg_masked = masked[begin:stop]
                if '=' not in seg_masked:
                    continue
                # Leading layout (a stripped Javadoc block is a long run of
                # spaces) must go before the regex sees the statement.
                begin += len(seg_masked) - len(seg_masked.lstrip())
                seg_masked = masked[begin:stop]
                if not INTERFACE_FIELD_RE.match(seg_masked):
                    continue
                pairs = _const_names_with_values(clean[begin:stop], seg_masked)
                if pairs:
                    matches.append((begin, pairs))

    if not matches:
        return []
    depths = brace_depth_at(masked, [o for o, _ in matches])
    consts = []
    seen_ids = set()
    for off, pairs in matches:
        d = depths[off]
        owner = None
        for c in classes:
            if c['body_depth'] < d and (owner is None or c['body_depth'] > owner['body_depth']):
                owner = c
        owner_fqn = owner['fqn'] if owner else None
        prefix = (owner_fqn + '.' if owner_fqn else (pkg + '.' if pkg else ''))
        for nm, str_val in pairs:
            if nm in KEYWORDS or nm in ('true', 'false', 'null'):
                continue
            cid = prefix + nm
            if cid in seen_ids:
                continue
            seen_ids.add(cid)
            consts.append({
                'name': nm,
                'id': cid,
                'class_fqn': owner_fqn,
                'value': str_val,
                'line': line_of(clean, off),
            })
    return consts


def find_private_methods(clean, class_names):
    """Names of private method declarations, excluding constructors and framework annotated methods."""
    return [name for name, _ in find_private_methods_with_lines(clean, class_names)]


def find_private_fields(clean):
    """Names of private field declarations, supporting multi-variable declarations on one line."""
    return [name for name, _ in find_private_fields_with_lines(clean)]


def find_private_methods_with_lines(clean, class_names):
    """(name, line) for each private method declaration."""
    masked = mask_strings(clean)
    names = []
    method_pattern = re.compile(
        r'(?<![\w.])(?:@[\w.$]+(?:\([^)]*\))?\s+)*'
        r'private\s+'
        r'(?:@[\w.$]+(?:\([^)]*\))?\s+)*'
        r'(?:(?:static|final|abstract|synchronized|native|default|strictfp)\s+)*'
        r'(?:<[^>]+>\s+)?'
        r'([\w$<>,\s?\[\].]+?)\s+'
        r'(\w+)\s*\(',
        re.MULTILINE
    )

    for m in method_pattern.finditer(masked):
        last_delim = max(clean.rfind(';', 0, m.start()), clean.rfind('}', 0, m.start()), clean.rfind('{', 0, m.start()))
        prefix = clean[last_delim + 1:m.start()] if last_delim >= 0 else clean[:m.start()]
        annotations = re.findall(r'@([A-Za-z_$][\w$]*)', prefix + clean[m.start():m.end()])
        if any(ann in FRAMEWORK_METHOD_ANNOTATIONS for ann in annotations):
            continue

        name = m.group(2)
        if name in KEYWORDS or name in ('true', 'false', 'null') or name in class_names:
            continue
        if name in SPECIAL_PRIVATE_METHODS:
            continue
        names.append((name, line_of(clean, m.start(2))))
    return names


def find_private_fields_with_lines(clean):
    """(name, line) for each private field declaration."""
    masked = mask_strings(clean)
    field_stmt_pattern = re.compile(
        r'(?<![\w.])(?:@[\w.$]+(?:\([^)]*\))?\s+)*'
        r'private\s+'
        r'(?:@[\w.$]+(?:\([^)]*\))?\s+)*'
        r'(?:(?:static|final|volatile|transient)\s+)*'
        r'(?!class\b|interface\b|enum\b|record\b|@interface\b)'
        r'([\w$<>,\s?\[\].]+?)\s+'
        r'([^;]+);',
        re.MULTILINE
    )

    names = []
    for m in field_stmt_pattern.finditer(masked):
        last_delim = max(clean.rfind(';', 0, m.start()), clean.rfind('}', 0, m.start()), clean.rfind('{', 0, m.start()))
        prefix = clean[last_delim + 1:m.start()] if last_delim >= 0 else clean[:m.start()]
        annotations = re.findall(r'@([A-Za-z_$][\w$]*)', prefix + clean[m.start():m.end()])
        if any(ann in FRAMEWORK_METHOD_ANNOTATIONS for ann in annotations):
            continue

        type_segment = m.group(1)
        field_segment = m.group(2)
        if '(' in type_segment or ')' in type_segment or 'throws' in type_segment or 'throws' in field_segment:
            continue

        field_names = _const_names(field_segment + ';')
        line = line_of(clean, m.start(2))
        for fname in field_names:
            if fname in KEYWORDS or fname in ('true', 'false', 'null'):
                continue
            if fname in SPECIAL_PRIVATE_FIELDS:
                continue
            names.append((fname, line))
    return names


def count_method_usages(clean, names):
    """Count call sites, method references, and targeted reflective/annotation invocations."""
    counts = defaultdict(int)
    name_set = set(names)
    for m in re.finditer(r'\b(\w+)\s*\(', clean):
        if m.group(1) in name_set:
            counts[m.group(1)] += 1
    for m in re.finditer(r'::\s*(\w+)', clean):
        if m.group(1) in name_set:
            counts[m.group(1)] += 1
    
    # Targeted reflection & JUnit annotations (e.g. @MethodSource("foo"), getDeclaredMethod("foo"))
    # Does NOT match generic log strings like "update complete"
    ref_pattern = re.compile(
        r'(?:@MethodSource\s*\(\s*(?:value\s*=\s*)?|(?:getDeclaredMethod|getMethod|invokeMethod|findMethod)\s*\(\s*)["\'](\w+)["\']'
    )
    for m in ref_pattern.finditer(clean):
        if m.group(1) in name_set:
            counts[m.group(1)] += 1
    return counts


def parse_java_file(filepath):
    """Parse one Java file into the facts every detector needs.

    Kept at module level and free of shared state so it can run in a worker
    process.
    """
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
    except OSError:
        return None
    clean = strip_comments_protect_strings(content)
    masked = mask_strings(clean)
    pkg = extract_package(clean)
    classes = collect_classes(clean, pkg, masked)
    return {
        'file': filepath,
        'pkg': pkg,
        'clean': clean,
        'classes': classes,
        'imports': extract_imports(clean),
        'constants': collect_constants(clean, pkg, classes, masked),
    }


def resolve_jobs(jobs):
    """Turn a --jobs value into a worker count (0 or None means autodetect)."""
    if jobs and jobs > 0:
        return jobs
    return min(8, os.cpu_count() or 1)


class ClassIndex:
    """Index of all defined classes plus per-file reference resolution.

    Each file is read and parsed exactly once; the per-file facts are shared
    with the constant and private-member detectors through `meta`.
    """

    def __init__(self, roots, exclusions, jobs=1):
        self.roots = list(roots)
        self.exclusions = list(exclusions)
        self.jobs = resolve_jobs(jobs)
        self.class_by_fqn = {}
        self.top_by_simple = defaultdict(list)
        self.nested_by_name = defaultdict(list)
        self.files = []
        self.meta = {}
        self._build()

    def _parsed_files(self):
        paths = list(walk_files(self.roots, self.exclusions))
        if self.jobs <= 1 or len(paths) < 200:
            return (parse_java_file(p) for p in paths)
        chunk = max(1, len(paths) // (self.jobs * 8))
        pool = ProcessPoolExecutor(max_workers=self.jobs)
        try:
            # Materialised so the pool can be shut down before the caller
            # starts its own work.
            return list(pool.map(parse_java_file, paths, chunksize=chunk))
        finally:
            pool.shutdown()

    def _build(self):
        for parsed in self._parsed_files():
            if parsed is None:
                continue
            filepath = parsed['file']
            pkg = parsed['pkg']
            defined = []
            for c in parsed['classes']:
                fqn = c['fqn']
                if fqn not in self.class_by_fqn:
                    c2 = dict(c)
                    c2['file'] = filepath
                    c2['pkg'] = pkg
                    self.class_by_fqn[fqn] = c2
                    if c['top_level']:
                        self.top_by_simple[c['name']].append(fqn)
                    else:
                        self.nested_by_name[c['name']].append(fqn)
                defined.append(fqn)
            self.files.append(filepath)
            self.meta[filepath] = {
                'pkg': pkg,
                'clean': parsed['clean'],
                'classes': parsed['classes'],
                'imports': parsed['imports'],
                'constants': parsed['constants'],
                'defined': defined,
            }

    def count_content(self, filepath):
        """The file body used for reference counting, without imports/package."""
        me = self.meta.get(filepath)
        if not me:
            return ''
        cached = me.get('count_content')
        if cached is None:
            cached = strip_imports_and_package(me['clean'])
            me['count_content'] = cached
        return cached

    def scope_for(self, filepath):
        """Map a simple name to the class FQNs it can denote in this file."""
        me = self.meta.get(filepath)
        if not me:
            return {}
        scope = {}
        for imp in me['imports']:
            if imp['static']:
                continue
            simple = imp['fqn'].rsplit('.', 1)[-1]
            scope.setdefault(simple, set()).add(imp['fqn'])
        for fqn in me['defined']:
            scope.setdefault(fqn.rsplit('.', 1)[-1], set()).add(fqn)
        for fqn, c in self.class_by_fqn.items():
            if c['top_level'] and c['pkg'] == me['pkg']:
                scope.setdefault(c['name'], set()).add(fqn)
        return scope

    def resolve_token(self, simple, scope):
        """Resolve a simple class name to FQNs; None when ambiguous."""
        sc = scope.get(simple)
        if sc:
            defined = {f for f in sc if f in self.class_by_fqn}
            if len(defined) == 1:
                return defined
            return None
        uniq = self.top_by_simple.get(simple)
        if uniq and len(uniq) == 1:
            return {uniq[0]}
        return None

    def resolve_chain(self, chain, scope):
        """Resolve a dotted identifier chain (Class, Class.Inner, pkg.Class)."""
        segs = chain.split('.')
        res = set()
        start = 0
        while start < len(segs) and not (segs[start][:1].isupper() or segs[start] in scope):
            start += 1
        if start < len(segs):
            bases = self.resolve_token(segs[start], scope)
            if bases:
                for base in bases:
                    cur = base
                    for s in segs[start + 1:]:
                        nxt = cur + '.' + s
                        if nxt in self.class_by_fqn:
                            cur = nxt
                            res.add(nxt)
                        else:
                            break
                    res.add(base)
        if not res:
            parts = chain.split('.')
            for i in range(len(parts), 0, -1):
                cand = '.'.join(parts[:i])
                if cand in self.class_by_fqn:
                    res.add(cand)
                    break
        return res

    def count_refs(self, filepath):
        """Count references to defined classes found in this file."""
        me = self.meta.get(filepath)
        if not me:
            return defaultdict(int)
        scope = self.scope_for(filepath)
        refs = defaultdict(int)
        content = self.count_content(filepath)
        for m in TOKEN_RE.finditer(content):
            resolved = self.resolve_token(m.group(1), scope)
            if resolved:
                for f in resolved:
                    self._credit(refs, f)
        for m in CHAIN_RE.finditer(content):
            for f in self.resolve_chain(m.group(0), scope):
                self._credit(refs, f)
        return refs

    def _credit(self, refs, fqn):
        """Count a reference to fqn and to every class enclosing it."""
        while True:
            refs[fqn] += 1
            c = self.class_by_fqn.get(fqn)
            if c is None or c['top_level']:
                return
            fqn = fqn.rsplit('.', 1)[0]
            if fqn not in self.class_by_fqn:
                return


def count_non_java_classes(index, roots, exclusions):
    """Count class references in text files other than Java sources."""
    refs = defaultdict(int)
    for filepath in walk_files(roots, exclusions, extensions=NON_JAVA_EXTENSIONS):
        try:
            with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except OSError:
            continue
        for m in TOKEN_RE.finditer(content):
            tok = m.group(1)
            uniq = index.top_by_simple.get(tok)
            if uniq and len(uniq) == 1:
                refs[uniq[0]] += 1
        for m in CHAIN_RE.finditer(content):
            full = m.group(0)
            if full in index.class_by_fqn:
                refs[full] += 1
    return refs


PREFILTER_N = 4


def count_non_java_constants(const_by_id, by_simple, roots, exclusions):
    """Count constant references in configuration / XML / property files by value and distinct name."""
    refs = defaultdict(int)

    # Reverse lookup by literal String value. Values are bucketed by their
    # first PREFILTER_N characters so a file only has to be searched for the
    # handful of values whose prefix actually occurs in it; testing every
    # value against every file was quadratic on real workspaces.
    by_value = defaultdict(list)
    short_values = defaultdict(list)
    for cid, k in const_by_id.items():
        val = k.get('value')
        if not val or len(val) < 3:
            continue
        if len(val) < PREFILTER_N:
            short_values[val].append(cid)
        else:
            by_value[val[:PREFILTER_N]].append((val, cid))

    for filepath in walk_files(roots, exclusions, extensions=NON_JAVA_EXTENSIONS):
        try:
            with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except OSError:
            continue

        # Match by literal string value (e.g. <command id="org.eclipse.ui.navigate" />)
        for val, cids in short_values.items():
            if val in content:
                for cid in cids:
                    refs[cid] += 1
        if by_value:
            grams = {content[i:i + PREFILTER_N]
                     for i in range(len(content) - PREFILTER_N + 1)}
            for gram in grams.intersection(by_value):
                for val, cid in by_value[gram]:
                    if val in content:
                        refs[cid] += 1

        # Match by distinct constant name (skipping generic short names like ID, NAME, TYPE)
        for m in TOKEN_RE.finditer(content):
            tok = m.group(1)
            if tok in by_simple and tok not in GENERIC_CONST_NAMES and len(tok) >= 4:
                for cid in by_simple[tok]:
                    refs[cid] += 1
    return refs


def is_internal(filepath):
    return 'internal' in filepath.replace('\\', '/').lower()


def is_test_source(filepath):
    """Whether the file lives in a test tree or matches a JUnit name pattern."""
    p = filepath.replace('\\', '/').lower()
    if '/tests/' in p or '/test/' in p or '.tests.' in p or '/src/test/' in p:
        return True
    name = os.path.basename(filepath)
    # "Test" only counts as a prefix when a new word starts after it, so
    # Testament.java is not mistaken for a test.
    if re.match(r'^(?:Test[A-Z0-9_$].*|.*(?:Test|Tests|TestCase|TestSuite))\.java$', name):
        return True
    return False


def add_common_args(ap, what, test_refs=True):
    """Register the options every detector shares."""
    ap.add_argument('roots', nargs='+', help='root directories to scan')
    ap.add_argument('--internal-only', action='store_true',
                    help=f'only report {what} under a package containing "internal"')
    ap.add_argument('--skip-tests', action='store_true',
                    help=f'do not report {what} in test trees')
    if test_refs:
        ap.add_argument('--ignore-test-refs', action='store_true',
                        help='ignore references originating from test code '
                             f'(surfaces {what} only used in unit tests)')
    ap.add_argument('--exclude', action='append', default=[],
                    help='extra path fragment to exclude (repeatable)')
    ap.add_argument('--jobs', type=int, default=0, metavar='N',
                    help='parse files with N worker processes (default: autodetect)')
    ap.add_argument('--format', choices=['tsv', 'json', 'markdown', 'summary'], default='tsv',
                    help='output format (default: tsv)')
    ap.add_argument('--fail-on-findings', action='store_true',
                    help='exit with status 1 when candidates are reported (for CI)')
    return ap


def emit(rows, headers, tag, args):
    """Print the rows in the requested format and return the process exit code."""
    out = format_output(rows, headers, tag=tag, fmt=args.format)
    if out:
        print(out)
    return 1 if (rows and getattr(args, 'fail_on_findings', False)) else 0


def format_output(rows, headers, tag="RESULT", fmt="tsv"):
    """Format detection results as TSV, JSON, Markdown, or Summary."""
    if fmt == "json":
        data = []
        for r in rows:
            item = dict(zip(headers, r))
            data.append(item)
        return json.dumps(data, indent=2)

    if fmt == "markdown":
        if not rows:
            return f"No results found for {tag}."
        lines = []
        lines.append("| " + " | ".join(headers) + " |")
        lines.append("| " + " | ".join(["---"] * len(headers)) + " |")
        for r in rows:
            lines.append("| " + " | ".join(str(x) for x in r) + " |")
        return "\n".join(lines)

    if fmt == "summary":
        summary_lines = [
            f"=== {tag} Summary ===",
            f"Total Candidates: {len(rows)}"
        ]
        # Break the count down by the categorical columns, addressed by name so
        # detectors with different column layouts all summarise correctly.
        for column in ('Type', 'Kind', 'Area', 'Confidence', 'Source', 'Usage', 'Reason'):
            if column not in headers:
                continue
            idx = headers.index(column)
            counts = defaultdict(int)
            for r in rows:
                if idx < len(r):
                    counts[str(r[idx])] += 1
            if len(counts) < 2:
                continue
            summary_lines.append(f"  {column}:")
            for k, v in sorted(counts.items()):
                summary_lines.append(f"    {k}: {v}")
        return "\n".join(summary_lines)

    out_lines = []
    for r in rows:
        out_lines.append(f"{tag}\t" + "\t".join(str(x) for x in r))
    return "\n".join(out_lines)
