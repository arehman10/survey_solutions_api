# Validation — SuSo v1.7.36 centered timing columns

- The existing source-generated DOM regression passed, including computed CSS
  checks for centered numeric headings/values and left-aligned section names.
  Existing filter, total, assignment and example checks passed in the same run.
- The presentation change is scoped to the selected-interview timing table.
  Calculation and indexing code, and the Java JAR, are unchanged.
- Package/root/install equality, recovery bytes and manifest checks passed.
- Native-browser pixel layout, licensed Stata and Windows/O: execution remain
  unverified. No additional calculation or download tests were run for this CSS edit.

## Prior v1.7.35 validation record

### v1.7.35 checks

- The source-generated DOM regression passed. It checks the five table headings,
  right alignment of numeric headings/values, left alignment and dark text for
  section names, panel padding, removal of the separate subtotal, and matching
  five-cell data rows.
- Existing history interactions passed: actor-less time remains in Active min,
  actor/event/search filters and periods still use the original full-chain
  intervals, assignment lookup works, and the synthetic example still totals
  6.50 active minutes. Question percentages, other report controls and embedded
  suite payload checks passed in the same existing regression.
- Root/install distribution equality, recovery bytes and the release manifest
  were verified during packaging. Timing allocation, local indexing and the
  Java JAR are unchanged; their earlier test results are recorded below.
- Checked DOM behavior and computed CSS in jsdom. No native-browser pixel/layout
  check, licensed Stata run or Windows/O: integration test was performed.

## Prior v1.7.34 validation record

### v1.7.34 checks

- All **13 offline JavaScript suites passed**, including the existing behaviour,
  section timing, skip, question-order and suite checks.
- **10 indexing groups** execute the exact emitted worker with real Blob slice
  reads in Node. Cases cover 1-byte through multi-record chunks, CR/LF/CRLF,
  Unicode, literal and quoted/multiline TSV, repeated/case-normalized IDs,
  non-first ID columns, fragmented ranges, memory-limit rescan fallback, source
  row/byte positions, cancellation during an old read, rejected prefetches,
  incomplete reads, invalid ID encoding and explicit blank-ID counts.
- **11 interview-section timing groups** verify all-role timing, named/unnamed
  subtotals, actor/event filtering after allocation, first/later reconciliation,
  unknown-question resets, automatic-event context, entirely unnamed sessions,
  handoffs, pauses, long gaps, invalid/missing timestamps, initial preload,
  quoted/roster parameters, empty scopes and exact custom-gap boundaries.
- DOM checks exercise percentage formatting (0.76 to 76.0%, zero and missing),
  unchanged numeric sorting, full-width history bullets, section-table filters,
  first/later periods, assignment lookup with one/multiple/missing matches,
  worker URL cleanup, and the focused synthetic history example. UI messaging
  uses a test double; the actual worker is tested separately. No pixel/browser
  layout screenshots were produced.

### Bounded indexing benchmark

`tools/benchmark_history.js` compared the v1.7.33 source with this indexer using
identical synthetic Blob inputs, alternating versions over three runs:

| Input | Size | Prior median | Updated median | Speed ratio |
| --- | ---: | ---: | ---: | ---: |
| 1,000,000 events, grouped into 10,000 interviews | 188,840,079 bytes | 1,328.0 ms | 597.8 ms | 2.22x |
| 300,000 interleaved events, 3,000 interviews | 56,652,079 bytes | 592.5 ms | 450.2 ms | 1.32x |

Both versions' event/interview counts and sample histories were verified.
These measure processing and in-memory Blob reads in Node/Linux, not browser
rendering, an O: drive, or actual survey file performance. A network-drive read
can still dominate the wait; a local copy may help. No server export speedup is
claimed by this update.

### Inspection and remaining limits

The complete question-to-section map and configured gap limit are emitted from
the report source. That Stata metadata wiring was inspected but not executed:
licensed Stata and actual SFI are unavailable. Run `examples/example.do` for
a synthetic Stata-to-HTML check before your real report. The displayed history
timing is an all-role estimate, distinct from the existing survey-wide
fieldwork-role derivation; unknown actors retain their raw identity.

The Java JAR is byte-identical to v1.7.32 (backend `1.7.32-SECTIONS`); Java and
download/publication behavior were not changed or retested. Package/root/install,
base64 recovery and release-manifest equality were verified. Real Stata/SFI,
Windows/SMB/O: integration and native-browser layout/performance remain unverified.

## Prior v1.7.33 validation record

- The source-generated Behaviour DOM regression passed, including navigation,
  question controls, section timing filters and the synthetic example.
- All seven existing suite DOM groups passed.
- Computed CSS checks confirmed seven guidance bullets, full table-width text,
  a 112 px priority column, 92 px minimum chip width and no wrapping. The review
  table retains a 620 px minimum width with horizontal scrolling on narrow views.
- The live question count and the variable/value filter limitation remain visible.
- The report JavaScript and packaged Java JAR are byte-for-byte unchanged from
  v1.7.32. This update changes presentation/copy and frontend version labels only.
- Root/install files and the packaged release manifest were verified.

No pixel-layout browser screenshots or licensed Stata/Windows execution were
performed for this update. Earlier calculation and backend validation is recorded
below; those tests were not needlessly repeated for these CSS/text edits.

## Prior v1.7.32 validation record

The new Section timing page is computed from compact per-interview, per-actor,
per-section rows. No real survey data were available. The downloadable example
uses illustrative payload values and the actual report HTML/CSS/JavaScript.

- All **11 offline JavaScript suites passed**, including **12 new section-timing
  groups** and both DOM suites. Checks cover per-interview contributor sums
  before quantiles, actor/status/value intersection (including value zero),
  first/rework/all reconciliation, unmapped-time conservation, untimed/unvisited
  denominators, timestamp counts, CSV scope/escaping and unchanged source data.
- DOM interactions verify live global filters while the Section timing page is
  open, period switches, section search/sort, empty scopes, no invented unvisited
  quantiles, and the focused example. Suite iframe payload identity is checked.
  These are DOM checks, not pixel/screenshot layout verification.
- A bounded synthetic Node.js probe of **40,000 interviews / 480,000 section
  rows** recalculated all-actor results in 464 ms and an actor scope in 162 ms,
  with counts verified. This is one compute-only measurement in this environment,
  not an end-to-end Stata or browser performance guarantee.
- `tests/section_timing_smoke.do` exercises the actual Stata allocator and Mata
  serializer: automatic events, unknown questions, actor/session boundaries,
  first/rework conservation, data preservation, empty streams and block output.
  It is included but **not run: licensed Stata is unavailable**.
- The rebuilt backend passed the existing regressions, **304 ZIP assertions**,
  **16 atomic-publication assertions**, eleven HTTP groups and file-publication
  checks. The parser still matches both original questionnaire fixtures and
  676 expressions; all 5,000 category values/labels remain complete. Java
  behavior is unchanged in this release apart from version identifiers.
- Eight progress, eleven download-flow, six folder-flow and eight data-path
  static checks passed, as did the Python download-manifest verifier.
- All seven bridge signatures and eleven SFI descriptors match the original
  binary. The JAR contains 31 Java 11 SuSo classes, with no compile-only SFI
  declarations included. Package/root/install and manifest verification passed.

Build/testing used Java 17/Linux with `--release 11` and temporary native SFI
API declarations. Actual Stata/SFI execution, Windows/O: share integration and
real survey report generation remain unverified. Use `examples/example.do` for
a synthetic end-to-end Stata run before generating the real report. Earlier
secure download, exact-folder and progress corrections are retained.

## Prior v1.7.31 validation record

This update addresses the user's non-monotonic preparation percentage and
Windows `journal.next -> journal.json` publication failure. The user log
confirms that job 17779's ZIP download succeeded before extraction failed;
the actual archive and the user's O: filesystem were not available here.

- **304 ZIP assertions passed** on the combined JAR: immutable journal
  snapshots, denied journal publication, complete/incomplete rollback,
  pending-state retention, unchanged-target recognition, and all earlier
  archive validation/exact-folder cases. Denial cases are injected Linux
  tests, not an emulation or execution of Windows/SMB behavior.
- **16 atomic-publication assertions passed**: transient and permanent access
  denial, bounded waits, no deletion fallback, cancellation, fresh-name
  collisions and actual atomic replacement on the Linux test filesystem.
- Original backend and file-publication regressions, eleven HTTP groups,
  actual local HTTPS certificate/hostname/auth/redirect tests and the Python
  v1/v2 manifest verifier all passed.
- Eight progress, eleven download-flow, six folder-flow and eight data-path
  static source checks passed. `tests/export_progress_smoke.do` exercises
  the real formatter/router/polling with a mocked API and checks both reported
  sequences, raw return preservation and completion gating. It is included
  but **not executed because licensed Stata is unavailable**.
- All ten offline report JavaScript suites passed, including both DOM suites;
  the synthetic preview was regenerated from the current ADO.
- The original parser comparison passed two questionnaire fixtures and 676
  expressions, with all 5,000 category values/labels intact. All seven public
  bridge signatures and eleven SFI descriptors match the original binary;
  the JAR contains 31 Java 11 SuSo classes and no SFI classes.

Build/testing used Java 17/Linux with `--release 11`. Compilation used temporary
native SFI declarations matching the original binary, excluded from the package.
Actual Stata execution, the real SFI runtime, Java 11 runtime execution, Windows
locking/ACL behavior and the user's O: filesystem remain unverified. A temporary
lock is a possible cause of the reported rename failure; the log does not prove
that diagnosis. Persistent permission failures still stop safely.

## Prior v1.7.30 validation record

This candidate fixes the exact-folder regression shown in the user's Windows
run. The preceding v1.7.29 build successfully downloaded/extracted the data and
loaded 3,985,019 paradata events, but moved the data export into a sibling of
the folder used by relative report paths. No live survey data files were made
available for this fix. No licensed Stata runtime is available in this build
environment, so v1.7.30 Stata/Windows integration still requires the user's run.

### v1.7.30 checks

- **224 transactional ZIP assertions passed**, including exact-folder output,
  unrelated-file preservation, independent backups of replaced files, complete
  validation before publication, rollback after a mid-publication failure,
  retained recovery state after an incomplete rollback, and rejection of a
  second extraction while a transaction is pending. See
  `tests/ZIP_TRANSACTION_VALIDATION.md` for the covered cases and limits.
- Original backend regressions, file-publication tests and all eleven HTTP
  regression groups passed. Actual local HTTPS tests passed for certificate
  trust, hostname verification, downgrade rejection, current-request
  authorization and SSL-context isolation.
- Six new folder-flow source checks, eleven download-flow source checks and
  eight data-path source checks passed. The public offline extraction parser
  and the supplied recovery do-file were reviewed together. These source checks
  do not execute Stata.
- Python verification passed v1/v2 manifests, same-size corruption, missing
  files, shared-folder scope, exact per-run manifest paths and unsafe paths.
  A separate integration probe extracted the supplied two-file synthetic ZIP
  into an existing folder containing its source archive and an unrelated report;
  both remained unchanged, and Python verified both Java-generated manifests.
- All ten offline JavaScript suites passed on the final ADO, including fourteen
  report-calculation groups and both DOM interaction suites. Preview HTML was
  regenerated from the current templates with explicitly synthetic data.
- Two questionnaire fixtures and 676 expressions remained identical to the
  original parser; all 5,000 test category values and labels were exported.
- All seven bridge signatures and eleven SFI invocation descriptors still
  match the original binary. The candidate contains **28 Java 11 SuSo classes
  and no SFI classes**. Two source builds produced byte-identical JARs.

These checks ran on Java 17/Linux. Compilation used temporary native API
declarations matching the shipped SFI descriptors; they are not packaged.
The v1.7.30 Stata commands, Windows/SMB filesystem behavior, Java 11 runtime and
actual survey report generation remain unverified. Handled publication errors
are tested; recovery from abrupt machine or network-storage failure is not.
The extraction is atomic per file, not across the entire destination folder.

The following historical record is retained for the earlier download and
report work; its benchmark timings are not measurements of v1.7.30.

## Prior v1.7.29 validation record

This is a candidate for the user's local run. No GitHub push, deployment or live
Survey Solutions mutation was performed. No licensed Stata runtime was available.

## Download and extraction validation

- Eleven HTTP regression groups passed: connection reuse/isolation, same-origin
  redirects, safe POST/byte-body behavior, bounded transient GET retries,
  deadline/cancellation behavior, successful hash/byte counts, invalid and
  incomplete ZIP downloads, and prior-file preservation.
- Real local HTTPS tests passed for trusted/untrusted certificates, hostname
  verification, insecure-download rejection, current-request authorization,
  downgrade rejection and SSL-context isolation. Test certificates are generated
  locally and removed by `tests/run-http-tls.sh`.
- File-publication tests passed for new downloads, independent prior copies,
  preservation after later edits, and directory/symlink rejection.
- Eleven Stata download-flow source guards and eight prior data-path source guards
  passed. These are static checks. `tests/download_flow_smoke.do` is included
  but remains unrun without Stata.
- Offline manifest verification passed valid-folder, same-size corruption,
  missing-file, extra-file and unsafe-path checks.

The final combined JAR passed the original backend regressions, publication
tests, eleven HTTP groups, actual local HTTPS tests and **133 transactional ZIP
assertions**. ZIP checks include late corruption, correct/wrong passwords,
ZIP64, unsafe paths/aliases, local/central metadata discrepancies and misleading
end records in archive comments. The independent Python verifier also checked
all 57,000,057 bytes of an actual synthetic benchmark extraction against its
generated manifest.

All seven bridge signatures and eleven SFI invocation descriptors still match
the originally shipped binary. The candidate contains **25 Java 11 SuSo classes
and no SFI classes**. Two questionnaire fixtures and 676 expression cases remained
identical to the original parser, with all 5,000 test category values and labels
exported. All ten JavaScript suites passed on the final ADO, including both DOM
interaction suites. No live survey data were used.

## Speed observations

Eight sequential local HTTP requests used eight TCP connections in v1.7.28 and
one in v1.7.29. Loopback wall times were 279 ms and 580 ms respectively. This
proves connection reuse, not a measured internet speedup.

Encrypted extraction of a 600,000-row synthetic paradata file (57,000,057 bytes
expanded; 8,463,342-byte archive) took a median 168.4 ms previously and 210.5 ms
with staging, SHA-256 and file synchronization. Each version had one warm-up
and five measured runs on Java 17/Linux, with output hashes checked. The added
checks cost about 42 ms in this probe. Extraction was already buffered; no
extraction speedup is claimed. Real transfer speed and server preparation time
remain unmeasured.

## Retained report checks

| Area | Validation and result |
|---|---|
| Report calculations | Fourteen regression groups exercise live speed/night thresholds, secondary-actor inclusion, actor attribution, no cross-actor pooling, reference populations, mode/clock suppression, lite settings, filter immutability and cutoff boundaries. Passed. |
| Existing browser logic | Seven prior suites cover behaviour, Data QC, question ordering, removal inventory, skip filters, history and suite shell. Passed. |
| Data paths | Eight source regression checks cover shared missing-value policy, bounded trigger selection, reduced schemas and complete option validation. Passed. These are source checks, not Stata execution. |
| Java backend | Local HTTP, ZIP, questionnaire and SFI-error probes passed, including stalled response bodies, cancellation cleanup and destination preservation. See `tests/JAVA_VALIDATION.md`. |
| Recovered parser | Two historical questionnaire fixtures and 676 expression cases matched the original binary; 5,000 option values and labels exported completely. Passed. |
| Java compatibility | The v1.7.29 bridge preserves the shipped public and SFI interfaces; see the combined validation above. |
| Build consistency | Repeated Java builds produced identical bytes. The package helper verifies root/install equality, recovery payload identity and archive hashes. |

The final integrated source passed all ten offline JavaScript suites. This
includes the seven baseline suites, the fourteen-group metrics suite, the
template DOM interaction suite, and seven suite-layout DOM groups. UI harnesses
were updated for the new navigation and compound-quoted template writers.
Checks exercise the secondary-actor queue, selected evidence, focus return,
search and filters, removal navigation, raw local history, Data QC, keyboard
tabs, mirrored controls, iframe payload equality and frame resizing logic.

## Run the checks yourself

From the extracted package root:

```sh
python3 tests/run_offline.py
python3 tests/data_path_source_regression.py
python3 tests/download_flow_source_regression.py
python3 tests/folder_flow_source_regression.py
python3 tests/export_progress_source_regression.py
python3 tests/verify_download_regression.py
```

For DOM interaction checks, install the pinned test-only dependency with
`npm --prefix tests ci`, then run `python3 tests/run_offline.py --dom`.
These checks execute emitted HTML and JavaScript in jsdom. They do not verify
rendered appearance in a desktop browser.

Java validation needs a JDK. To rebuild, supply your real Stata SFI API:

```sh
./build.sh /path/to/sfi-api.jar
./tests/run-java.sh dist/suso.jar
bash tests/run-http-tls.sh dist/suso.jar
```

To test actual Stata execution, use a fresh Stata session, follow the local setup
in `README.md`, save any dataset you want to keep, and run:

```stata
do "examples/example.do"
do "tests/data_path_smoke.do"
do "tests/option_integration_smoke.do"
do "tests/download_flow_smoke.do"
do "tests/folder_flow_smoke.do"
do "tests/export_progress_smoke.do"
```

The example writes the real generated suite and its log under
`examples/generated/`. Its illustrative HTML preview is a separate template
demonstration, so its counts need not match the Stata-generated output.

## Remaining runtime checks

- End-to-end Stata execution and integration with the real SFI API.
- Appearance, scrolling and focus behavior in the user's desktop browser.
- Execution on a Java 11 runtime, Windows builds and PowerShell recovery.
- Live Survey Solutions calls against the user's test workspace.

The shipped JAR was compiled with temporary native API declarations matching
the original binary's SFI descriptors. Those declarations are not bundled in
the production JAR or source tree. This establishes binary interface parity,
but does not replace a Stata runtime test.

## Large-input calculation probe

On this build host, a synthetic lite-report benchmark with 30,000 interviews,
60,000 actor records and 200 enumerators took approximately 1.28 seconds for
filtering, aggregation and the enumerator table in Node.js. Retained heap grew
by about 300 MB. This is a calculation probe, not a browser rendering benchmark
or a guarantee for a particular machine. Large reports may require substantial
browser memory.
