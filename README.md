# RCP Review Tools

This repository contains a collection of shell scripts designed to assist in analyzing, maintaining, and optimizing Eclipse RCP (Rich Client Platform) applications and Maven-based builds.

## Tools Overview

### 1. Feature Dependency Graph (`feature-dependency-graph.sh`)

Visualizes the dependency tree of Eclipse Products and Features. It builds a graph showing how products include features, and how features include/require other features.

*   **Purpose:** To understand the structure of your application, identify deep dependencies, and detect cycles.
*   **Usage:** `./feature-dependency-graph.sh [directory]`
*   **Key Features:**
    *   Scans `.product` and `feature.xml` files.
    *   Visualizes `includes` and `requires` relationships.
    *   Aggregates plugin counts per feature.
    *   Detects and flags external (missing) dependencies.
    *   Supports targeting a specific root feature ID.

### 2. Target Platform Analysis (`target-platform-analysis.sh`)

Compares entries in an Eclipse Target Platform file (`.target`) against the actual Maven dependency tree.

*   **Purpose:** To identify unused or extraneous entries in your Target Platform definition that are not actually being pulled in by the Maven build.
*   **Usage:** `./target-platform-analysis.sh <target-file.target> [maven-tree-output.txt]`
*   **Key Features:**
    *   Parses standard Eclipse `.target` files.
    *   Can automatically generate a Maven dependency tree (requires `mvn` in path).
    *   Highlights target entries missing from the build dependencies.

### 3. Target Platform Manifest Search (`target-platform-manifest-search.sh`)

Extracts entries from a Target Platform file and searches for their usage directly within the `MANIFEST.MF` files of your workspace bundles.

*   **Purpose:** To identify "potentially unnecessary" target entries by checking if any local bundle actually imports packages or bundles provided by the target entries.
*   **Usage:** `./target-platform-manifest-search.sh <target-file.target> [search-directory]`
*   **Key Features:**
    *   Deep scan of `MANIFEST.MF` files (Require-Bundle, Import-Package).
    *   Reports target entries that appear to be unused by any local source code.

### 4. Target Platform Duplicates (`target-platform-duplicates.sh`)

Identifies bundles that appear in the resolved Tycho target platform under more than one version. Uses the XML dump produced by Tycho when resolution runs with `-Dtycho.target-platform.dump=true`.

*   **Purpose:** To detect version conflicts in the target platform (same symbolic name resolved to multiple versions), which typically cause hard-to-diagnose runtime issues.
*   **Usage:** `./target-platform-duplicates.sh [options] [dump-file-or-directory]`
*   **Key Features:**
    *   With no arguments, runs `mvn -q dependency:tree -Dtycho.target-platform.dump=true` and scans every `*/target/target-platform-*.xml` produced in the reactor.
    *   Accepts a directory (scanned recursively) or a single dump file as input.
    *   Groups `<unit>` entries by symbolic name and reports any id with more than one distinct version.
    *   `-f` / `--features` includes feature IUs (`*.feature.group`); by default only plug-ins are considered.
    *   `-a` / `--all` additionally prints the full symbolic-name inventory.
    *   Works on Linux and Windows (Git Bash, WSL, Cygwin).

### 5. Binary Artifact Scanner (`scan_for_binary_artifacts.sh`)

Scans the codebase for binary artifacts such as images, documents, archives, and compiled binaries.

*   **Purpose:** To audit the repository for large or unwanted binary files, counting them and calculating their total size.
*   **Usage:** `./scan_for_binary_artifacts.sh [directory]`
*   **Key Features:**
    *   Categorizes files (Images, Docs, Archives, Binaries).
    *   Calculates counts and total size per category.
    *   Useful for repo cleanup and size optimization.

### 6. Remove Features from Build (`remove-features-from-build.sh`)

Recursively finds `pom.xml` files and comments out modules ending in `.feature`.

*   **Purpose:** To quickly disable feature modules from a Maven build, typically for creating stripped-down builds or debugging build issues.
*   **Usage:** `./remove-features-from-build.sh [directory] [--apply]`
*   **Key Features:**
    *   **Dry Run:** By default, it only lists what it *would* change.
    *   **Apply Mode:** Use `--apply` to actually modify the `pom.xml` files.
    *   Comments out `<module>...feature</module>` lines.

### 7. Analyze Build Times (`analyze_build_times.py`)

Analyzes build times from a build output file.

*   **Purpose:** To extract and analyze timing information from build logs to identify performance bottlenecks.
*   **Usage:** `python3 analyze_build_times.py <file_path>`
*   **Key Features:**
    *   Parses various time formats (e.g., "5.990 s", "01:50 min", "1.5 min").
    *   Takes a build output file as input.

### 8. Eclipse Project Analyzer (`eclipse-project-analyser.sh`)

Recursively analyzes Eclipse RCP projects (plugins, features, products) within a given workspace path and generates a Markdown report.

*   **Purpose:** To get a comprehensive overview of an Eclipse RCP workspace, including project types, versions, and code statistics.
*   **Usage:** `./eclipse-project-analyser.sh <workspace-path> [output-file]`
*   **Key Features:**
    *   Identifies plugin projects (`META-INF/MANIFEST.MF`, `plugin.xml`).
    *   Identifies feature projects (`feature.xml`).
    *   Identifies product definitions (`.product` files).
    *   Extracts names, versions, and counts Java files.
    *   Generates a detailed Markdown report with summaries, project lists, statistics, and a directory structure.
    *   Ignores common build/version control directories (`.git`, `target`, `bin`, etc.).

### 9. Java Class Counter (`java-class-counter.sh`)

Counts lines of Java code, separating production code from test code, and provides statistics per project and overall.

*   **Purpose:** To get a detailed breakdown of Java code lines, distinguishing between production and test code, and identifying code size per project.
*   **Usage:** `./java-class-counter.sh [directory]`
*   **Key Features:**
    *   Distinguishes between production and test code based on file path (e.g., `test/`, `tests/`).
    *   Counts total lines, code lines, blank lines, and comment lines.
    *   Provides statistics for each detected project.
    *   Calculates a "Test-Code-Ratio" (Test-Lines / Prod-Lines).

### 10. Scan JARs (`scan_jars.sh`)

Scans for `.jar` files within `lib` or `libs` directories and generates a Markdown report.

*   **Purpose:** To audit third-party dependencies packaged as JARs within projects, identify their locations, and get a global overview of unique JARs and their usage frequency.
*   **Usage:** `./scan_jars.sh [directory]`
*   **Key Features:**
    *   Recursively searches for `lib` or `libs` directories, excluding common build/version control directories.
    *   Generates a Markdown report (`jar_dependencies_report.md`).
    *   Lists JAR files found within each identified plugin's `lib`/`libs` directory.
    *   Provides a global summary of unique JARs and their occurrence count.

### 11. Search Manifest Usage (`search_manifest_usage.sh`)

Recursively searches all `MANIFEST.MF` files for the usage of a certain library (e.g., `riena`) in `Require-Bundle` and `Import-Package` headers.

*   **Purpose:** To find where a specific library or package is referenced across all Eclipse plugins in a repository.
*   **Usage:** `./search_manifest_usage.sh <search-directory> <library-name>`
*   **Key Features:**
    *   Parses multi-line `MANIFEST.MF` headers correctly.
    *   Searches both `Require-Bundle` and `Import-Package`.
    *   Highlights the matching entry in the output.
    *   **Case-insensitive:** The search is case-insensitive.
    *   Works on Linux and Windows.

### 12. Remove Re-exports (`remove_reexports.sh`)

Removes `;visibility:=reexport` from `MANIFEST.MF` files for Eclipse plug-ins and generates a report.

*   **Purpose:** To eliminate re-exporting of bundles, promoting cleaner dependency management and reducing unnecessary classpath exposure.
*   **Usage:** `./remove_reexports.sh [--dry-run]`
*   **Key Features:**
    *   Recursively scans for `MANIFEST.MF` files.
    *   Correctly handles complex `Require-Bundle` entries, including version ranges with commas.
    *   Generates a detailed report: "Re-exported plug-in" | "Exported by:".
    *   **Dry Run:** Use `--dry-run` to generate the report without modifying files.
    *   Works on Linux and Windows (Git Bash).

### 13. Update JRE Container (`update_jre_container.sh`)

Recursively finds `.classpath` files and replaces the JRE container entry that has module attributes with a standard JavaSE-17 entry.

*   **Purpose:** To standardize the JRE container configuration across Eclipse projects, ensuring they all use `JavaSE-17`, and to remove specific module attributes that might cause issues or inconsistencies.
*   **Usage:** `./update_jre_container.sh [directory] [--dry-run]`
*   **Key Features:**
    *   **Configurable Search Path:** Allows specifying a root directory to scan (defaults to the current directory).
    *   **Dry Run Mode:** Use `--dry-run` to preview which files would be updated without modifying them.
    *   **Recursive Search:** Finds all `.classpath` files in the specified directory and subdirectories.
    *   **Multi-line Replacement:** Correctly identifies and replaces JRE container entries even when split across multiple lines with indentation.
    *   **Preserves Indentation:** Maintains the original file's indentation (tabs/spaces) for the replaced entry.

### 13. Update Eclipse SWT (`update-eclipse-swt.sh`)

Updates an Eclipse installation with locally built SWT jars and native libraries. Patches the `Bundle-Version` in the built jars to match the installed version so that OSGi resolution continues to work.

*   **Purpose:** To quickly test local SWT changes in a full Eclipse installation.
*   **Usage:** `./update-eclipse-swt.sh [ECLIPSE_DIR]`
*   **Key Features:**
    *   **Version Patching:** Automatically matches the `Bundle-Version` to the installed one.
    *   **Automatic Backups:** Creates `.bak` files of original jars before replacement.
    *   **Supports GTK/Linux:** Specifically targets `org.eclipse.swt` and `org.eclipse.swt.gtk.linux.x86_64`.
    *   **Cleanup:** Provides instructions to restore original jars.

## Compatibility

These scripts are written in Bash and are compatible with:
*   **Linux**
*   **Windows** (via Git Bash, WSL, or Cygwin)
*   **macOS** (Requires Bash 4.0+ for associative array support in some scripts)

## Requirements

*   **Bash 4.0+**
*   **Python 3** (Required for `analyze_build_times.py`)
*   **Perl** (Required for `remove_reexports.sh` and `update_jre_container.sh`)
*   Standard GNU tools: `awk`, `sed`, `grep`, `find`, `sort`
*   **Maven (`mvn`)** (Required only for `target-platform-analysis.sh` if generating tree automatically)