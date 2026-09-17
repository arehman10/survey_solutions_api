#!/usr/bin/env bash
# Run focused backend regressions against a built or packaged JAR, without Stata.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
ARTIFACT="${1:-$ROOT/dist/suso.jar}"
JAVA="${SUSO_JAVA:-java}"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"
if command -v javac >/dev/null 2>&1; then
  COMPILER=(javac)
else
  COMPILER=("$JAVA" -m jdk.compiler/com.sun.tools.javac.Main)
fi
"${COMPILER[@]}" --release 11 -Xlint:all -cp "$ARTIFACT" -d "$OUT" "$HERE"/java/org/worldbank/suso/*.java
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.BackendRegressionTest
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.TransferFilesTest
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.AtomicFilesTest
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.HttpTransferRegressionTest
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.ZipTransactionTest
# Optional source-recovery differential test against the original shipped JAR.
if [ -n "${2:-}" ]; then
  "$JAVA" -cp "$OUT" QxRecoveryProbe "$2" "$ARTIFACT" \
    "$HERE/fixtures/enablement_smoke_questionnaire.html" \
    "$HERE/fixtures/tri_enablement_smoke_questionnaire.html"
fi
