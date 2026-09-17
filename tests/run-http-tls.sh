#!/usr/bin/env bash
# Optional live TLS test: creates and removes a local test-only certificate.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
ARTIFACT="${1:-$ROOT/dist/suso.jar}"
JAVA="${SUSO_JAVA:-java}"
KEYTOOL="${SUSO_KEYTOOL:-keytool}"
OUT="$ROOT/build/tls-tests"
CERTDIR="$(mktemp -d)"
trap 'rm -rf "$CERTDIR"' EXIT
mkdir -p "$OUT"
"$KEYTOOL" -genkeypair -alias suso-test -keyalg RSA -keysize 2048 \
  -validity 2 -dname "CN=localhost" -ext "SAN=dns:localhost" \
  -storetype PKCS12 -keystore "$CERTDIR/test.p12" \
  -storepass suso-test-only -keypass suso-test-only -noprompt >/dev/null 2>&1
if command -v javac >/dev/null 2>&1; then
  COMPILER=(javac)
else
  COMPILER=("$JAVA" -m jdk.compiler/com.sun.tools.javac.Main)
fi
"${COMPILER[@]}" --release 11 -Xlint:all -cp "$ARTIFACT" -d "$OUT" \
  "$HERE/java/org/worldbank/suso/HttpTlsRegressionTest.java"
"$JAVA" -cp "$ARTIFACT:$OUT" org.worldbank.suso.HttpTlsRegressionTest "$CERTDIR/test.p12"
