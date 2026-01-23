#!/bin/bash
set -euo pipefail

# This script searches for .classpath files and replaces the JRE_CONTAINER entry 
# that has module attributes with a standard JavaSE-17 entry.

# Default values
SEARCH_DIR="."
DRY_RUN="false"

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN="true"
            ;;
        -*)
            echo "Error: Unknown option '$arg'" >&2
            exit 1
            ;;
        *)
            if [ -d "$arg" ]; then
                SEARCH_DIR="$arg"
            else
                echo "Error: Directory '$arg' does not exist." >&2
                exit 1
            fi
            ;;
    esac
done

echo "Searching in: $SEARCH_DIR"
if [ "$DRY_RUN" = "true" ]; then
    echo "Running in DRY RUN mode. No files will be modified."
fi

export DRY_RUN
find "$SEARCH_DIR" -name ".classpath" -type f -print0 | xargs -0 -P 4 perl -e '
    use strict;
    use warnings;
    my $dry_run = ($ENV{DRY_RUN} eq "true");
    local $/; # Slurp mode
    foreach my $file (@ARGV) {
        open my $fh, "<", $file or do { warn "Cannot open $file: $!"; next; };
        my $content = <$fh>;
        close $fh;
        
        # Regex matches both:
        # 1. Complex entry with module="true" attribute
        # 2. Simple self-closing entry <classpathentry ... />
        if ($content =~ s/^([ \t]*)<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"(?:>\s*<attributes>\s*<attribute name="module" value="true"\/>\s*<\/attributes>\s*<\/classpathentry>|\s*\/>)/$1<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER\/org.eclipse.jdt.internal.debug.ui.launcher.StandardVMType\/JavaSE-17"\/>/gm) {
            if ($dry_run) {
                print "Would update: $file\n";
            } else {
                print "Updating: $file\n";
                open my $out, ">", $file or do { warn "Cannot write $file: $!"; next; };
                print $out $content;
                close $out;
            }
        }
    }
'

echo "Done."
