#!/bin/bash
set -euo pipefail

# This script recursively removes specific Eclipse PDE preference files
# (org.eclipse.pde.core.prefs and org.eclipse.pde.prefs)
# within .settings folders found in the current directory and its subdirectories.
# This is intended for cleaning up Eclipse PDE .settings files on Windows using Git Bash or WSL.

echo "Searching for .settings folders and removing specific PDE preference files..."

# Find all directories named ".settings"
find . -type d -name ".settings" -print0 | while IFS= read -r -d $'\0' settings_dir; do
    echo "Found .settings directory: $settings_dir"

    # Define the specific files to remove
    files_to_remove=(
        "org.eclipse.pde.core.prefs"
        "org.eclipse.pde.prefs"
    )

    for file_name in "${files_to_remove[@]}"; do
        file_path="${settings_dir}/${file_name}"
        if [ -f "$file_path" ]; then
            echo "Removing: $file_path"
            rm -f "$file_path"
            if [ $? -eq 0 ]; then
                echo "$file_name removed successfully."
            else
                echo "Error removing $file_name from ${settings_dir}."
            fi
        fi
    done
done

echo "Cleanup complete."