#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — compile suso.jar from source against your Stata's SFI library.
#
#   A prebuilt dist/suso.jar already ships with this package and should work
#   on any Stata with a Java 11+ runtime. Rebuild from source ONLY if the
#   prebuilt jar errors at runtime (e.g. a NoSuchMethodError), which would
#   indicate a different SFI on your Stata.
#
# Usage:
#   ./build.sh [/path/to/sfi-api.jar]
#   SFI_JAR=/path/to/sfi-api.jar ./build.sh
#
# To find sfi-api.jar, in Stata run:   display c(sysdir_stata)
# and look under that folder (commonly  utilities/jar/sfi-api.jar  or  utilities/).
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/build/classes"
DIST="$HERE/dist"

if ! command -v javac >/dev/null 2>&1; then
  echo "ERROR: javac not found. Install a JDK 11+ (Temurin/OpenJDK) and re-run." >&2
  exit 1
fi
echo "Using $(javac -version 2>&1)"

SFI="${1:-${SFI_JAR:-}}"
if [ -z "${SFI}" ]; then
  echo "Searching for sfi-api.jar in common Stata locations ..."
  for d in /Applications/Stata* /Applications/stata* /usr/local/stata* /opt/stata* "$HOME"/Stata* "$HOME"/stata*; do
    [ -d "$d" ] || continue
    f="$(find "$d" -name 'sfi-api.jar' 2>/dev/null | head -1 || true)"
    if [ -n "$f" ]; then SFI="$f"; break; fi
  done
fi
if [ -z "${SFI}" ] || [ ! -f "${SFI}" ]; then
  echo "ERROR: could not locate sfi-api.jar." >&2
  echo "  In Stata:  display c(sysdir_stata)   then find sfi-api.jar under that folder." >&2
  echo "  Re-run  :  ./build.sh /full/path/to/sfi-api.jar" >&2
  exit 1
fi
echo "Using SFI: $SFI"

rm -rf "$OUT"; mkdir -p "$OUT" "$DIST"
javac --release 11 -Xlint:all -cp "$SFI" -d "$OUT" "$SRC"/org/worldbank/suso/*.java
( cd "$OUT" && jar cf "$DIST/suso.jar" org/worldbank/suso )
echo "Built: $DIST/suso.jar"
echo "Now copy suso.jar, suso.ado and suso.sthlp to your Stata PLUS or PERSONAL folder"
echo "(see 'display c(sysdir_plus)' / 'display c(sysdir_personal)' in Stata)."
