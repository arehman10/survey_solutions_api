# Java backend validation for the local 1.7.28 review build

This file records the source-recovery validation performed for v1.7.28. For
the current v1.7.30 transfer/extraction changes and combined JAR validation,
see `../TEST_RESULTS.md` and `ZIP_TRANSACTION_VALIDATION.md`.

The missing questionnaire source was recovered from the user's shipped JAR with CFR, restored to compilable source, and compared against that binary. The readable existing Stata bridge was retained and the shipped `qxmeta`, `sfiabi`, path handling, UTF-8 byte widths, and checked SFI return calls were restored. The recovered HTTP/ZIP repair sources retain the shipped redirect, extraction-containment, integrity, and atomic replacement behavior.

Changes add complete questionnaire option values and labels, a complete-response timeout with explicit cancellation, and reproducible JAR packaging. The configured read timeout applies to headers and complete body consumption **per HTTP hop**; redirects receive the same configured limit. A failed or timed-out download leaves the old destination intact and removes its temporary file.

Run after building against the real SFI API supplied by Stata:

```sh
./build.sh /path/to/sfi-api.jar
./tests/run-java.sh dist/suso.jar
```

An optional comparison with the originally shipped JAR checks recovered questionnaire semantics and the complete bridge ABI:

```sh
./tests/run-java.sh dist/suso.jar /path/to/original/suso.jar
python3 tests/check-java-abi.py /path/to/original/suso.jar dist/suso.jar
```

The Java regression suite uses local synthetic HTTP and questionnaire inputs. It checks ZIP traversal, symlink escape, CRC errors and existing-file preservation; HTTP 307 method/body preservation (including byte uploads), 303 conversion, complete/truncated downloads, stalled headers and bodies, cancellation cleanup, recovery after cancellation, scoped TLS configuration, UTF-8 string widths, nonzero SFI return handling, and a complete 61-option export. The differential probe checks two historical enablement fixtures, 676 expression cases, and 5,000 option values and labels.

For this review build, all these checks passed on OpenJDK 17 while targeting Java 11. Two source builds produced byte-identical JARs. All seven public Stata bridge signatures and all 11 SFI invocation descriptors match the originally shipped binary. The JAR contains 18 SuSo classes and no SFI classes.

No licensed Stata runtime or real SFI API was available in this environment. Compilation used temporary native API declarations matching the original JAR's descriptors; those declarations are absent from the production JAR and this source tree. Runtime execution in Stata, live Survey Solutions calls, Java 11 runtime execution, Windows `build.bat`, and the PowerShell recovery script remain unverified. The PowerShell recovery logic was reviewed: it uses its own directory, validates the decoded payload against `suso.jar.sha256`, and only then atomically replaces an existing JAR.
