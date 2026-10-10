#!/bin/sh
# Deletes the run-path entries of a Mach-O executable that point outside the app bundle and the
# OS, then checks none is left (every architecture). SwiftPM adds the toolchain's folder inside
# Xcode.app; dyld would search it before Contents/Frameworks, so whoever can write there (any
# admin on a Mac without Xcode) could have the input method load their librime.
# Usage: Scripts/strip-rpaths.sh EXECUTABLE   (before signing: it changes the binary)
set -eu
binary=$1

# The LC_RPATH paths from `otool -l` output on stdin, one per line and whole (Xcode may sit in a
# folder with spaces), except those in the bundle (@…) or the OS (/usr/lib/…).
outside() {
    awk '
        $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
        rpath && $1 == "path" {
            p = $0
            sub(/^[ \t]*path /, "", p)
            sub(/ \(offset [0-9]+\)$/, "", p)
            if (p !~ /^@/ && p !~ /^\/usr\/lib\//) print p
        }' | sort -u
}

# Run here, not in a pipeline, so a failing otool stops the script.
commands=$(otool -l "$binary")
printf '%s\n' "$commands" | outside | while IFS= read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$binary"
done
commands=$(otool -l "$binary")
left=$(printf '%s\n' "$commands" | outside)
if [ -n "$left" ]; then
    echo "error: $binary still has run paths outside the bundle: $left" >&2
    exit 1
fi
