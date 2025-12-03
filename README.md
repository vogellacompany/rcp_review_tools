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

### 4. Binary Artifact Scanner (`scan_for_binary_artifacts.sh`)

Scans the codebase for binary artifacts such as images, documents, archives, and compiled binaries.

*   **Purpose:** To audit the repository for large or unwanted binary files, counting them and calculating their total size.
*   **Usage:** `./scan_for_binary_artifacts.sh [directory]`
*   **Key Features:**
    *   Categorizes files (Images, Docs, Archives, Binaries).
    *   Calculates counts and total size per category.
    *   Useful for repo cleanup and size optimization.

### 5. Remove Features from Build (`remove-features-from-build.sh`)

Recursively finds `pom.xml` files and comments out modules ending in `.feature`.

*   **Purpose:** To quickly disable feature modules from a Maven build, typically for creating stripped-down builds or debugging build issues.
*   **Usage:** `./remove-features-from-build.sh [directory] [--apply]`
*   **Key Features:**
    *   **Dry Run:** By default, it only lists what it *would* change.
    *   **Apply Mode:** Use `--apply` to actually modify the `pom.xml` files.
    *   Comments out `<module>...feature</module>` lines.

## Compatibility

These scripts are written in Bash and are compatible with:
*   **Linux**
*   **Windows** (via Git Bash, WSL, or Cygwin)
*   **macOS** (Requires Bash 4.0+ for associative array support in some scripts)

## Requirements

*   **Bash 4.0+**
*   Standard GNU tools: `awk`, `sed`, `grep`, `find`, `sort`
*   **Maven (`mvn`)** (Required only for `target-platform-analysis.sh` if generating tree automatically)