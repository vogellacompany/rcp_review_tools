# Dead Code Detector

Heuristic tools to find dead code in large Java source trees such as the
Eclipse Platform. All tools accept one or more root directories; the first
root is the tree to clean and additional roots are scanned for references
(so a class used from `eclipse.platform.ui` is not reported as dead when
scanning `eclipse.platform`).

Every result is a candidate for manual review, not a proof that the symbol
is unused. Reflection, build files outside the scanned roots, and other
repositories can still reference the symbol.

## Tools

| Tool | Detects |
| --- | --- |
| `find_dead_classes.py` | Classes never referenced outside their own definition or enclosing file |
| `find_dead_constants.py` | Public/protected `static final` constants never used |
| `find_unused_imports.py` | Unused imports (with optional `--fix`) |
| `find_dead_private.py` | Private methods never called and private fields never read |
| `find_outdated_code.py` | Outdated idioms, suspicious error handling and likely slow code (rule based) |

`run_all.sh <root>` runs all five in sequence.

## Usage

```bash
python3 find_dead_classes.py <root> [extra_roots ...] [options]
python3 find_dead_constants.py <root> [extra_roots ...] [options]
python3 find_unused_imports.py <root> [--fix] [options]
python3 find_dead_private.py <root> [options]
python3 find_outdated_code.py <root> [options]
./run_all.sh <root> [extra_roots ...] [--only NAME[,NAME...]] [options]
```

### Common Options

* `--internal-only`: Only reports hits under a package containing `internal`.
* `--skip-tests`: Skips hits in test trees (classes/constants that JUnit runs
  by name pattern are not dead even when nothing references them). Supported
  consistently across all four tools and `run_all.sh`.
* `--ignore-test-refs`: Treats references originating from test code as unused,
  surfacing production classes/constants whose only remaining caller is a unit test.
  Results indicate `UNUSED` (0 references anywhere) vs `TEST_ONLY` (0 production references).
  Only `find_dead_classes.py` and `find_dead_constants.py` accept it; the other
  two never look past the declaring file.
* `--exclude FRAGMENT`: Excludes paths containing the fragment (repeatable).
* `--jobs N`: Parses files in `N` worker processes. The default autodetects,
  `--jobs 1` forces a single process.
* `--min-confidence high`: Drops the `VERIFY` hits (`find_dead_classes.py` and
  `find_dead_constants.py`).
* `--format {tsv,json,markdown,summary}`: Output format (default is `tsv`).
* `--fail-on-findings`: Exits with status 1 when candidates were reported, so a
  CI job can gate on a clean tree.
* `find_unused_imports.py --ignore-javadoc`: Also treats imports referenced
  only from Javadoc (`{@link Foo}`) as unused; without it they are reported
  as `JAVADOC_ONLY`, matching Eclipse's default behaviour of keeping them.
* `find_unused_imports.py --fix`: Removes the unused import statements directly
  from the files while cleaning up blank lines in import blocks.
* `run_all.sh --only classes,constants,imports,private,outdated`: Runs a subset
  of the detectors. The script exits non-zero if any detector did.
* `find_outdated_code.py --list-rules`: Prints the rule table.
  `--rules ID[,ID...]` runs a subset, `--category OUTDATED|BAD|SLOW` filters by
  category, `--min-confidence high` drops the `VERIFY` rules.

## Output

### Default TSV Output

```
DEAD_CLASS\tfile\tclass\tTOPLEVEL|INNER\tINTERNAL|EXTERNAL_API\tHIGH|VERIFY\tCODE|TEST\tUNUSED|TEST_ONLY
DEAD_CONSTANT\tfile\tname\tINTERNAL|EXTERNAL_API\tHIGH|VERIFY\tCODE|TEST\tUNUSED|TEST_ONLY
UNUSED_IMPORT\tfile\tline\timport\tCLASS|STATIC\tINTERNAL|EXTERNAL_API\treason
DEAD_PRIVATE_METHOD\tfile\tline\tname\tINTERNAL|EXTERNAL_API
DEAD_PRIVATE_FIELD\tfile\tline\tname\tINTERNAL|EXTERNAL_API
OUTDATED_CODE\tfile\tline\trule\tOUTDATED|BAD|SLOW\tHIGH|VERIFY\tINTERNAL|EXTERNAL_API\tCODE|TEST\tmessage\tsnippet
```

* `HIGH`: The simple name is unique in the scanned tree and the analysis is conclusive.
* `VERIFY`: The name collides with another symbol and the result needs a manual check.
* `TEST`: Marks hits in test sources; a JUnit test class is usually run by name pattern.

### Structured Output Formats

* `--format json`: Formats the results as a JSON array of objects, ideal for CI/CD integrations.
* `--format markdown`: Renders GitHub-flavored Markdown tables.
* `--format summary`: Displays the candidate count broken down by every
  categorical column that has more than one value.

## Accuracy notes

* **Constructor & self-reference handling**: Top-level classes with constructors,
  factory methods, or self-types are not dismissed as alive. Classes are evaluated
  on external workspace references and non-Java references.
* **Inner class usage scoping**: Inner classes are checked for usage within their
  enclosing parent classes.
* **Constant modifier order**: All modifier permutations are supported
  (`public final static`, `static public final`, `final protected static`).
* **Multi-declaration support**: Comma-separated constant and field declarations
  are parsed (`public static final int A = 1, B = 2;`).
* **Non-Java reference scanning**: Constant and class references are found in XML,
  `.properties`, `.product`, `.target`, `.exsd`, `.launch`, and other configuration files.
* **Framework & DI annotation awareness**: Reflectively invoked members are ignored
  (`@Inject`, `@Execute`, `@PostConstruct`, `@PreDestroy`, `@FXML`, `@Test`,
  `@EventHandler`), as are the Java serialization hooks (`readObject`, `writeObject`,
  `serialVersionUID`).
* **Accurate import scoping**: Implicit `java.lang.*` imports are distinguished from
  explicit subpackages such as `java.lang.reflect.*`.

## Performance

The detectors are meant to run over a whole Eclipse repository, so the file
parse happens once per file and is shared between the class, constant and
import analyses, and it is spread over worker processes.

Two inputs used to make a run effectively hang, both fixed:

* Interface bodies are split into statements before the constant regex sees
  them. Matching a lazy pattern against a whole body backtracked quadratically,
  which stalled for minutes on a large interface such as `IResource`.
* Constant string values are bucketed by prefix before configuration files are
  searched, instead of testing every value against every file.

On `eclipse.pde` (about 6,400 Java files), `find_dead_constants.py` went from
not finishing within ten minutes to well under a minute.

## Testing

```bash
python3 -m unittest discover -s . -p "test_*.py"
```

## Workflow

1. Run `find_unused_imports.py --fix` first so lingering unused imports do
   not mask dead classes.
2. Run the other three detectors, optionally with the other Eclipse
   repositories as extra roots, and pass `--skip-tests` unless test code is
   in scope.
3. Re-run the detectors after a batch of deletions; `VERIFY` hits and any
   hit in an `internal` package that other bundles import deserve an extra
   check with `git grep <fqn>`.
