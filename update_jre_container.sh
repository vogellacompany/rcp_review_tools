#!/bin/bash

# This script searches for .classpath files and replaces the JRE_CONTAINER entry 
# that has module attributes with a standard JavaSE-17 entry.

find . -name ".classpath" -type f | while read -r file; do
    echo "Processing $file..."
    
    # Use perl for multi-line replacement, capturing leading indentation
    perl -i -0777 -pe 's/^([ \t]*)<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER">\s*<attributes>\s*<attribute name="module" value="true"\/>\s*<\/attributes>\s*<\/classpathentry>/$1<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER\/org.eclipse.jdt.internal.debug.ui.launcher.StandardVMType\/JavaSE-17"\/>/gm' "$file"
done

echo "Done."
