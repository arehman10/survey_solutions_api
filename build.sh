#!/usr/bin/env bash
# Build the complete Java 11 backend against the real SFI API supplied with Stata.
# Usage: ./build.sh /path/to/sfi-api.jar (or set SFI_JAR).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SFI="${1:-${SFI_JAR:-}}"
if [ -z "$SFI" ]; then
  for d in /Applications/Stata* /Applications/stata* /usr/local/stata* /opt/stata* "$HOME"/Stata* "$HOME"/stata*; do
    [ -d "$d" ] || continue
    f="$(find "$d" -name 'sfi-api.jar' -print -quit 2>/dev/null || true)"
    if [ -n "$f" ]; then SFI="$f"; break; fi
  done
fi
if [ -z "$SFI" ] || [ ! -f "$SFI" ]; then
  echo "ERROR: supply your Stata sfi-api.jar. In Stata: display c(sysdir_stata)" >&2
  exit 1
fi
JAVA="${SUSO_JAVA:-java}"
if command -v javac >/dev/null 2>&1; then
  COMPILER=(javac)
else
  # Some installations expose JDK modules but omit the javac launcher.
  COMPILER=("$JAVA" -m jdk.compiler/com.sun.tools.javac.Main)
fi
OUT="$HERE/build/classes"
TOOL="$HERE/build/tools"
DIST="$HERE/dist"
rm -rf "$OUT" "$TOOL"
mkdir -p "$OUT" "$TOOL" "$DIST"
"${COMPILER[@]}" --release 11 -Xlint:all -cp "$SFI" -d "$OUT" "$HERE"/src/org/worldbank/suso/*.java
"${COMPILER[@]}" --release 11 -d "$TOOL" "$HERE/tools/BuildJar.java"
"$JAVA" -cp "$TOOL" BuildJar "$OUT" "$DIST/suso.jar"
echo "Built $DIST/suso.jar (SuSo classes only; SFI remains supplied by Stata)."
