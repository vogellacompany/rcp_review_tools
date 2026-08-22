#!/usr/bin/env python3
"""Unit test suite for the dead-code-detector tools."""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import java_analysis as ja

HERE = os.path.dirname(os.path.abspath(__file__))


def run_detector(script, *args):
    """Run one detector script regardless of the caller's working directory."""
    return subprocess.run([sys.executable, os.path.join(HERE, script), *args],
                          capture_output=True, text=True)
from find_dead_classes import is_inner_class_used
from find_unused_imports import analyze_file as analyze_imports, fix_file
from find_dead_private import analyze_file as analyze_private


class TestJavaAnalysis(unittest.TestCase):

    def test_strip_comments_protect_strings(self):
        code = '''
        // line comment
        String s = "hello // not a comment /* neither */";
        /* multi
           line
           comment */
        String block = """
            text block with // and /*
        """;
        int x = 42;
        '''
        clean = ja.strip_comments_protect_strings(code)
        self.assertIn('"hello // not a comment /* neither */"', clean)
        self.assertIn('"""\n            text block with // and /*\n        """', clean)
        self.assertNotIn('line comment', clean)
        self.assertNotIn('multi\n           line', clean)
        self.assertIn('int x = 42;', clean)

    def test_mask_strings(self):
        code = 'String s = "SecretClass"; String b = """AnotherClass""";'
        masked = ja.mask_strings(code)
        self.assertNotIn("SecretClass", masked)
        self.assertNotIn("AnotherClass", masked)
        self.assertEqual(len(code), len(masked))

    def test_collect_classes_records_interfaces(self):
        code = '''
        package com.example;
        public class Outer<T> {
            public interface InnerInterface {
            }
            record InnerRecord(int a, String b) {}
            enum InnerEnum { FOO, BAR }
        }
        class PackagePrivateClass {}
        '''
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")
        names = [c['name'] for c in classes]
        fqns = [c['fqn'] for c in classes]
        self.assertIn("Outer", names)
        self.assertIn("InnerInterface", names)
        self.assertIn("InnerRecord", names)
        self.assertIn("InnerEnum", names)
        self.assertIn("PackagePrivateClass", names)
        self.assertIn("com.example.Outer.InnerRecord", fqns)
        self.assertIn("com.example.PackagePrivateClass", fqns)

    def test_collect_constants_permutations_and_multi(self):
        code = '''
        package com.example;
        public class MyConstants {
            public static final int A = 1, B = 2;
            static public final String C = "hello";
            final public static long D = 100L;
            protected static final int[] ARR = { 1, 2, 3 };
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")
        consts = ja.collect_constants(clean, "com.example", classes)
        names = [c['name'] for c in consts]
        self.assertEqual(sorted(names), ['A', 'ARR', 'B', 'C', 'D'])

    def test_static_final_class_is_not_a_constant(self):
        code = '''
        package com.example;
        public class Outer {
            public static final int REAL = 1;
            public final static class Inner implements Runnable, Comparable<Inner> {
                public void run() { int x = 1; }
                public int compareTo(Inner o) { return 0; }
            }
            public static final class Plain { }
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")
        consts = ja.collect_constants(clean, "com.example", classes)
        self.assertEqual([c['name'] for c in consts], ['REAL'])

    def test_nested_class_reference_keeps_outer_alive(self):
        with tempfile.TemporaryDirectory() as d:
            pkg = os.path.join(d, 'src', 'com', 'example')
            os.makedirs(pkg)
            with open(os.path.join(pkg, 'Outer.java'), 'w') as f:
                f.write('package com.example;\nclass Outer {\n'
                        '    static class Inner { }\n}\n')
            with open(os.path.join(pkg, 'User.java'), 'w') as f:
                f.write('package com.example;\n'
                        'import com.example.Outer.Inner;\n'
                        'class User {\n    Inner i = new Inner();\n}\n')
            index = ja.ClassIndex([d], [], jobs=1)
            refs = index.count_refs(os.path.join(pkg, 'User.java'))
            self.assertGreater(refs['com.example.Outer.Inner'], 0)
            self.assertGreater(refs['com.example.Outer'], 0)

    def test_implicit_interface_constants(self):
        code = '''
        package com.example;
        public interface IConstants {
            int IMPLICIT_INT = 10;
            String IMPLICIT_STR = "org.eclipse.example";
            public static final boolean EXPLICIT = true;
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")
        consts = ja.collect_constants(clean, "com.example", classes)
        names = [c['name'] for c in consts]
        self.assertIn('IMPLICIT_INT', names)
        self.assertIn('IMPLICIT_STR', names)
        self.assertIn('EXPLICIT', names)
        
        # Verify string value capture
        str_const = next(c for c in consts if c['name'] == 'IMPLICIT_STR')
        self.assertEqual(str_const['value'], 'org.eclipse.example')

    def test_interface_constants_ignore_bodies_and_annotation_arguments(self):
        code = '''
        package com.example;
        public interface IEvents {
            int MODELS_ADDED = 0x1;

            @Deprecated(since = "4.4", forRemoval = true)
            int TARGET_CHANGED = 0x8;

            String[] NAMES = { "a", "b" };

            default String first() {
                String[] tokens = getTokens();
                return tokens[0];
            }

            String[] getTokens();

            class Mode {
                private final String fName;
                Mode(String name) {
                    fName = name;
                }
            }
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")
        names = [c['name'] for c in ja.collect_constants(clean, "com.example", classes)]
        self.assertIn('MODELS_ADDED', names)
        # An annotated declaration is still a constant ...
        self.assertIn('TARGET_CHANGED', names)
        # ... but the annotation's own arguments are not.
        self.assertNotIn('since', names)
        self.assertNotIn('forRemoval', names)
        # An array initializer does not hide the constant it belongs to.
        self.assertIn('NAMES', names)
        # Locals in a default method and assignments in a nested constructor
        # are not interface constants.
        self.assertNotIn('tokens', names)
        self.assertNotIn('fName', names)

    def test_large_interface_body_is_not_quadratic(self):
        # A stripped Javadoc block leaves a long run of whitespace in front of
        # every declaration; matching that with a lazy pattern used to hang.
        filler = '/**\n' + (' * doc\n' * 400) + ' */\n'
        body = ''.join(f'{filler}    int CONST_{i} = {i};\n' for i in range(120))
        code = f'package com.example;\npublic interface IBig {{\n{body}}}\n'
        clean = ja.strip_comments_protect_strings(code)
        classes = ja.collect_classes(clean, "com.example")

        start = time.monotonic()
        names = [c['name'] for c in ja.collect_constants(clean, "com.example", classes)]
        elapsed = time.monotonic() - start

        self.assertEqual(len(names), 120)
        self.assertIn('CONST_119', names)
        self.assertLess(elapsed, 5.0, f"collect_constants took {elapsed:.1f}s")

    def test_private_methods_and_annotations(self):
        code = '''
        package com.example;
        public class Service {
            @Inject
            private void injectedMethod() {}

            @PostConstruct
            private void init() {}

            private void unusedMethod(String param) {}

            private <T> T unusedGeneric(Class<T> clazz) {}

            private void usedMethod() {}

            public void caller() {
                usedMethod();
            }
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        methods = ja.find_private_methods(clean, {'Service'})
        self.assertNotIn('injectedMethod', methods)
        self.assertNotIn('init', methods)
        self.assertIn('unusedMethod', methods)
        self.assertIn('unusedGeneric', methods)
        self.assertIn('usedMethod', methods)

    def test_private_fields_and_multi(self):
        code = '''
        package com.example;
        public class Data {
            private static final long serialVersionUID = 1L;
            private int x = 1, y = 2, z;
            @Inject private String injected;
            private String unused;
        }
        '''
        clean = ja.strip_comments_protect_strings(code)
        fields = ja.find_private_fields(clean)
        self.assertNotIn('serialVersionUID', fields)
        self.assertNotIn('injected', fields)
        self.assertIn('x', fields)
        self.assertIn('y', fields)
        self.assertIn('z', fields)
        self.assertIn('unused', fields)

    def test_is_test_source_prefix_needs_a_word_boundary(self):
        self.assertTrue(ja.is_test_source('/src/com/example/TestRunner.java'))
        self.assertTrue(ja.is_test_source('/src/com/example/RunnerTest.java'))
        self.assertTrue(ja.is_test_source('/src/com/example/RunnerTestCase.java'))
        self.assertFalse(ja.is_test_source('/src/com/example/Testament.java'))

    def test_summary_breaks_down_by_named_column(self):
        rows = [("A.java", "One", "INTERNAL", "HIGH", "CODE", "UNUSED"),
                ("B.java", "Two", "EXTERNAL_API", "VERIFY", "CODE", "UNUSED")]
        headers = ["File", "Constant", "Area", "Confidence", "Source", "Usage"]
        summary = ja.format_output(rows, headers, tag="DEAD_CONSTANT", fmt="summary")
        self.assertIn("Total Candidates: 2", summary)
        self.assertIn("Area:", summary)
        self.assertIn("INTERNAL: 1", summary)
        self.assertIn("Confidence:", summary)
        self.assertIn("VERIFY: 1", summary)
        # Columns with a single distinct value add no information
        self.assertNotIn("Usage:", summary)


class TestDeadCodeDetectorEndToEnd(unittest.TestCase):

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="dead_code_test_")

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_inner_class_instantiated_via_new_is_alive(self):
        # Inner class instantiated as new OnlyNew() in enclosing class
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        file_path = os.path.join(pkg_dir, "Enclosing.java")
        with open(file_path, "w") as f:
            f.write('''package com.example;
public class Enclosing {
    private class OnlyNew {
        OnlyNew() {}
    }
    public void create() {
        new OnlyNew();
    }
}
''')
        with open(file_path, "r") as f:
            clean = ja.strip_comments_protect_strings(f.read())
        classes = ja.collect_classes(clean, "com.example")
        inner_c = next(c for c in classes if c['name'] == 'OnlyNew')
        self.assertTrue(is_inner_class_used(clean, inner_c))

    def test_dead_class_with_constructor_is_detected(self):
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        dead_file = os.path.join(pkg_dir, "DeadWithConstructor.java")
        with open(dead_file, "w") as f:
            f.write('''package com.example;
            public class DeadWithConstructor {
                public DeadWithConstructor() {}
                public DeadWithConstructor(String x) {}
            }
            ''')

        live_file = os.path.join(pkg_dir, "LiveClass.java")
        with open(live_file, "w") as f:
            f.write('''package com.example;
            public class LiveClass {
                public static void main(String[] args) {}
            }
            ''')

        user_file = os.path.join(pkg_dir, "UserClass.java")
        with open(user_file, "w") as f:
            f.write('''package com.example;
            public class UserClass {
                void foo() {
                    LiveClass.main(null);
                }
            }
            ''')

        index = ja.ClassIndex([self.test_dir], ja.DEFAULT_EXCLUDE)
        refs_by_file = {fp: index.count_refs(fp) for fp in index.files}

        dead_fqn = "com.example.DeadWithConstructor"
        ext_refs = sum(refs.get(dead_fqn, 0) for fp, refs in refs_by_file.items() if fp != dead_file)
        self.assertEqual(ext_refs, 0)

        live_fqn = "com.example.LiveClass"
        ext_refs_live = sum(refs.get(live_fqn, 0) for fp, refs in refs_by_file.items() if fp != live_file)
        self.assertGreater(ext_refs_live, 0)

    def test_unused_imports_and_fix_preserves_method_blank_lines(self):
        file_path = os.path.join(self.test_dir, "Sample.java")
        content = '''package com.example;

import java.util.List;
import java.util.ArrayList;
import java.util.HashMap;

public class Sample {
    List<String> list = new ArrayList<>();


    public void methodWithDoubleBlanks() {
        System.out.println("Line 1");


        System.out.println("Line 2");
    }
}
'''
        with open(file_path, "w") as f:
            f.write(content)

        results = analyze_imports(file_path, ignore_javadoc=False)
        unused_fqns = [imp['fqn'] for imp, reason in results if reason.startswith('UNUSED')]
        self.assertEqual(unused_fqns, ['java.util.HashMap'])

        # Test fix
        fixes = fix_file(file_path, unused_fqns)
        self.assertEqual(fixes, 1)

        with open(file_path, "r") as f:
            new_content = f.read()
        self.assertNotIn("java.util.HashMap", new_content)
        self.assertIn("java.util.List", new_content)
        self.assertIn("java.util.ArrayList", new_content)
        # Ensure double blank lines in method body are strictly preserved
        self.assertIn('System.out.println("Line 1");\n\n\n        System.out.println("Line 2");', new_content)

    def test_dead_private_method_in_log_string_is_dead(self):
        file_path = os.path.join(self.test_dir, "LogTest.java")
        with open(file_path, "w") as f:
            f.write('''package com.example;
public class LogTest {
    private void update() {}

    public void run() {
        System.out.println("update complete");
    }
}
''')
        dead_methods, _ = analyze_private(file_path)
        # update() must be detected as dead despite appearing in log string
        self.assertEqual(dead_methods, [('update', 3)])

    def test_dead_private_members(self):
        file_path = os.path.join(self.test_dir, "PrivateTest.java")
        with open(file_path, "w") as f:
            f.write('''package com.example;
public class PrivateTest {
    private int unusedField = 10;
    private int usedField = 20;

    private void unusedMethod() {}
    private void usedMethod() {}

    public void run() {
        System.out.println(usedField);
        usedMethod();
    }
}
''')
        dead_methods, dead_fields = analyze_private(file_path)
        self.assertEqual(dead_methods, [('unusedMethod', 6)])
        self.assertEqual(dead_fields, [('unusedField', 3)])

    def test_format_output(self):
        rows = [("path/to/File.java", "UnusedClass", "TOPLEVEL", "INTERNAL", "HIGH", "CODE")]
        headers = ["File", "Class", "Kind", "Area", "Confidence", "Source"]

        tsv = ja.format_output(rows, headers, tag="DEAD_CLASS", fmt="tsv")
        self.assertTrue(tsv.startswith("DEAD_CLASS\tpath/to/File.java"))

        json_out = ja.format_output(rows, headers, tag="DEAD_CLASS", fmt="json")
        self.assertIn('"Class": "UnusedClass"', json_out)

        md = ja.format_output(rows, headers, tag="DEAD_CLASS", fmt="markdown")
        self.assertIn("| File | Class |", md)
        self.assertIn("| path/to/File.java | UnusedClass |", md)

    def test_unused_imports_subpackage_java_lang(self):
        file_path = os.path.join(self.test_dir, "LangSubpackage.java")
        with open(file_path, "w") as f:
            f.write('''package com.example;

import java.lang.reflect.Method;
import java.lang.annotation.Retention;

public class LangSubpackage {
}
''')
        results = analyze_imports(file_path, ignore_javadoc=False)
        unused_fqns = [imp['fqn'] for imp, reason in results if reason.startswith('UNUSED')]
        self.assertIn('java.lang.reflect.Method', unused_fqns)
        self.assertIn('java.lang.annotation.Retention', unused_fqns)

    def test_constant_matched_by_string_value_in_config(self):
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        java_file = os.path.join(pkg_dir, "CommandConstants.java")
        with open(java_file, "w") as f:
            f.write('''package com.example;
public class CommandConstants {
    public static final String NAV_CMD_ID = "org.eclipse.ui.navigate";
    public static final String UNUSED_CMD_ID = "org.eclipse.ui.unused";
}
''')
        xml_file = os.path.join(self.test_dir, "plugin.xml")
        with open(xml_file, "w") as f:
            f.write('''<plugin>
    <extension point="org.eclipse.ui.commands">
        <command id="org.eclipse.ui.navigate" />
    </extension>
</plugin>
''')
        index = ja.ClassIndex([self.test_dir], ja.DEFAULT_EXCLUDE)
        from find_dead_constants import build_const_index
        const_by_id, by_simple, meta = build_const_index(index)
        non_java_refs = ja.count_non_java_constants(const_by_id, by_simple, [self.test_dir], ja.DEFAULT_EXCLUDE)
        self.assertGreater(non_java_refs.get("com.example.CommandConstants.NAV_CMD_ID", 0), 0)
        self.assertEqual(non_java_refs.get("com.example.CommandConstants.UNUSED_CMD_ID", 0), 0)

    def test_run_all_script(self):
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        with open(os.path.join(pkg_dir, "Dummy.java"), "w") as f:
            f.write('''package com.example;
import java.util.List;
public class Dummy {
    private int deadField = 1;
    public static final int DEAD_CONST = 99;
}
''')
        script_path = os.path.join(os.path.dirname(__file__), "run_all.sh")
        proc = subprocess.run([script_path, self.test_dir, "--format", "summary"],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("DEAD_CLASS", proc.stdout)
        self.assertIn("DEAD_CONSTANT", proc.stdout)
        self.assertIn("UNUSED_IMPORT", proc.stdout)
        self.assertIn("DEAD_PRIVATE", proc.stdout)

    def _write_dummy(self):
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        with open(os.path.join(pkg_dir, "Dummy.java"), "w") as f:
            f.write('''package com.example;
import java.util.List;
public class Dummy {
    private int deadField = 1;
    public static final int DEAD_CONST = 99;
}
''')

    def test_run_all_only_selects_detectors(self):
        self._write_dummy()
        script_path = os.path.join(HERE, "run_all.sh")
        proc = subprocess.run([script_path, self.test_dir, "--only", "imports,private",
                               "--format", "summary"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("UNUSED_IMPORT", proc.stdout)
        self.assertIn("DEAD_PRIVATE", proc.stdout)
        self.assertNotIn("DEAD_CLASS", proc.stdout)
        self.assertNotIn("DEAD_CONSTANT", proc.stdout)

    def test_fail_on_findings_sets_exit_code(self):
        self._write_dummy()
        clean = run_detector("find_unused_imports.py", self.test_dir)
        self.assertEqual(clean.returncode, 0)
        self.assertIn("java.util.List", clean.stdout)

        failing = run_detector("find_unused_imports.py", self.test_dir, "--fail-on-findings")
        self.assertEqual(failing.returncode, 1)
        self.assertIn("java.util.List", failing.stdout)

    def test_reported_line_numbers(self):
        self._write_dummy()
        imports = run_detector("find_unused_imports.py", self.test_dir)
        self.assertIn("\t2\tjava.util.List\t", imports.stdout)

        private = run_detector("find_dead_private.py", self.test_dir)
        self.assertIn("\t4\tdeadField\t", private.stdout)

    def test_min_confidence_filters_verify_hits(self):
        # Two same-named classes in different packages collide, so both dead
        # candidates are reported as VERIFY.
        for pkg in ("one", "two"):
            pkg_dir = os.path.join(self.test_dir, "com", pkg)
            os.makedirs(pkg_dir, exist_ok=True)
            with open(os.path.join(pkg_dir, "Colliding.java"), "w") as f:
                f.write(f"package com.{pkg};\npublic class Colliding {{}}\n")

        all_hits = run_detector("find_dead_classes.py", self.test_dir)
        self.assertIn("VERIFY", all_hits.stdout)

        high_only = run_detector("find_dead_classes.py", self.test_dir,
                                 "--min-confidence", "high")
        self.assertNotIn("Colliding", high_only.stdout)

    def test_parallel_and_serial_agree(self):
        pkg_dir = os.path.join(self.test_dir, "com", "example")
        os.makedirs(pkg_dir, exist_ok=True)
        for i in range(250):
            with open(os.path.join(pkg_dir, f"Gen{i}.java"), "w") as f:
                f.write(f"package com.example;\npublic class Gen{i} {{\n"
                        f"    public static final String ID{i} = \"id.{i}\";\n}}\n")

        serial = run_detector("find_dead_constants.py", self.test_dir, "--jobs", "1")
        parallel = run_detector("find_dead_constants.py", self.test_dir, "--jobs", "4")
        self.assertEqual(serial.returncode, 0, serial.stderr)
        self.assertEqual(parallel.returncode, 0, parallel.stderr)
        self.assertEqual(sorted(serial.stdout.splitlines()),
                         sorted(parallel.stdout.splitlines()))
        self.assertIn("ID42", serial.stdout)


    def test_ignore_test_refs_surfaces_classes_used_only_in_tests(self):
        # Production class
        prod_dir = os.path.join(self.test_dir, "src", "com", "example")
        os.makedirs(prod_dir, exist_ok=True)
        with open(os.path.join(prod_dir, "StreamFilter.java"), "w") as f:
            f.write('''package com.example;
public class StreamFilter {
    public StreamFilter() {}
}
''')
        # Test class referencing StreamFilter
        test_dir = os.path.join(self.test_dir, "tests", "com", "example")
        os.makedirs(test_dir, exist_ok=True)
        with open(os.path.join(test_dir, "StreamFilterTest.java"), "w") as f:
            f.write('''package com.example;
public class StreamFilterTest {
    void testIt() {
        new StreamFilter();
    }
}
''')
        # 1. Run without --ignore-test-refs (StreamFilter considered alive because of test)
        res_alive = run_detector("find_dead_classes.py", self.test_dir, "--format", "tsv")
        self.assertEqual(res_alive.returncode, 0, res_alive.stderr)
        self.assertNotIn("StreamFilter\t", res_alive.stdout)

        # 2. Run with --ignore-test-refs (StreamFilter surfaced as TEST_ONLY dead candidate)
        res_dead = run_detector("find_dead_classes.py", self.test_dir,
                                "--ignore-test-refs", "--format", "tsv")
        self.assertEqual(res_dead.returncode, 0, res_dead.stderr)
        self.assertIn("StreamFilter\t", res_dead.stdout)
        self.assertIn("TEST_ONLY", res_dead.stdout)


if __name__ == '__main__':
    unittest.main()
