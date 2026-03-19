#!/bin/bash
#
# Updates an Eclipse installation with locally built SWT jars and native libraries.
# Patches the Bundle-Version in the built jars to match the installed version so
# that OSGi resolution continues to work.
#
# Usage: ./update-eclipse-swt.sh [ECLIPSE_DIR]
#   ECLIPSE_DIR defaults to /home/vogella/dev/eclipse-I2025-10-05/eclipse

set -euo pipefail

ECLIPSE_DIR="${1:-/home/vogella/dev/eclipse-I2025-10-05/eclipse}"
SWT_REPO="/home/vogella/git/eclipse.platform.swt"
PLUGINS_DIR="$ECLIPSE_DIR/plugins"

# Built artifacts
SWT_JAR="$SWT_REPO/bundles/org.eclipse.swt/target/org.eclipse.swt-3.133.0-SNAPSHOT.jar"
SWT_BINARY_JAR="$SWT_REPO/binaries/org.eclipse.swt.gtk.linux.x86_64/target/org.eclipse.swt.gtk.linux.x86_64-3.133.0-SNAPSHOT.jar"

# Validate
if [ ! -d "$PLUGINS_DIR" ]; then
	echo "ERROR: Plugins directory not found: $PLUGINS_DIR"
	exit 1
fi

for jar in "$SWT_JAR" "$SWT_BINARY_JAR"; do
	if [ ! -f "$jar" ]; then
		echo "ERROR: Built artifact not found: $jar"
		echo "Run 'mvn clean verify -DskipTests' first."
		exit 1
	fi
done

# Find existing SWT jars in the Eclipse installation
SWT_INSTALLED=$(find "$PLUGINS_DIR" -maxdepth 1 -name 'org.eclipse.swt_*.jar' ! -name '*source*' ! -name '*.bak' | head -1)
SWT_BINARY_INSTALLED=$(find "$PLUGINS_DIR" -maxdepth 1 -name 'org.eclipse.swt.gtk.linux.x86_64_*.jar' ! -name '*source*' ! -name '*.bak' | head -1)

if [ -z "$SWT_INSTALLED" ] || [ -z "$SWT_BINARY_INSTALLED" ]; then
	echo "ERROR: Could not find existing SWT jars in $PLUGINS_DIR"
	exit 1
fi

# Extract the installed Bundle-Version from the original jar (use backup if available)
get_installed_version() {
	local jar="$1"
	local source="$jar"
	if [ -f "$jar.bak" ]; then
		source="$jar.bak"
	fi
	unzip -p "$source" META-INF/MANIFEST.MF | grep '^Bundle-Version:' | sed 's/Bundle-Version: *//' | tr -d '\r\n'
}

INSTALLED_SWT_VERSION=$(get_installed_version "$SWT_INSTALLED")
INSTALLED_BINARY_VERSION=$(get_installed_version "$SWT_BINARY_INSTALLED")

echo "Updating SWT in: $ECLIPSE_DIR"
echo ""
echo "Installed versions:"
echo "  org.eclipse.swt: $INSTALLED_SWT_VERSION"
echo "  org.eclipse.swt.gtk.linux.x86_64: $INSTALLED_BINARY_VERSION"
echo ""
echo "Replacing:"
echo "  $(basename "$SWT_INSTALLED")"
echo "    <- $SWT_JAR"
echo "  $(basename "$SWT_BINARY_INSTALLED")"
echo "    <- $SWT_BINARY_JAR"
echo ""

# Backup originals (only if backup doesn't already exist)
for jar in "$SWT_INSTALLED" "$SWT_BINARY_INSTALLED"; do
	if [ ! -f "$jar.bak" ]; then
		cp "$jar" "$jar.bak"
		echo "Backed up: $(basename "$jar") -> $(basename "$jar").bak"
	fi
done

# Repack a jar with its Bundle-Version patched to the target version
# Args: source_jar target_version output_jar
repack_with_version() {
	local src_jar="$1"
	local target_version="$2"
	local out_jar="$3"

	local tmpdir
	tmpdir=$(mktemp -d)
	trap "rm -rf '$tmpdir'" RETURN

	# Extract
	unzip -q "$src_jar" -d "$tmpdir"

	# Patch Bundle-Version in MANIFEST.MF
	sed -i "s/^Bundle-Version: .*/Bundle-Version: $target_version/" "$tmpdir/META-INF/MANIFEST.MF"

	# Repackage (use stored compression to preserve jar format)
	(cd "$tmpdir" && jar cfm "$out_jar" META-INF/MANIFEST.MF $(ls -A | grep -v META-INF))
}

echo "Patching Bundle-Version to match installed versions..."

repack_with_version "$SWT_JAR" "$INSTALLED_SWT_VERSION" "$SWT_INSTALLED"
repack_with_version "$SWT_BINARY_JAR" "$INSTALLED_BINARY_VERSION" "$SWT_BINARY_INSTALLED"

echo ""
echo "Done! Start Eclipse with -clean to pick up changes:"
echo "  $ECLIPSE_DIR/eclipse -clean"
echo ""
echo "To restore originals:"
echo "  cp '$SWT_INSTALLED.bak' '$SWT_INSTALLED'"
echo "  cp '$SWT_BINARY_INSTALLED.bak' '$SWT_BINARY_INSTALLED'"
