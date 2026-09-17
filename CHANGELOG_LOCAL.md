# SuSo v1.7.37 — filter-aware interview search

Build: `2026-09-08-FILTERSEARCH`; unchanged backend: `1.7.32-SECTIONS`.
Nothing is pushed or published.

- Reproduced a matching lf_responsive=1 record disappearing because the duration
  benchmark recalculated and its Watch signal cleared. The old search operated
  only on flagged records; data membership was correct in the reproduction.
- Search now includes all matching interviews within the current data/actor/status
  filters, with explicit No signal labels. Default browsing remains a review
  queue. Added No active signals to the priority selector.
- Evidence shows the filter values saved at report generation. Empty-result
  messages distinguish priority mismatch from exclusion by the main filters.
- CSV export uses the same search/priority result across all pages. Duration
  evidence names the current comparison group. Calculations and KPI counts,
  Stata filter joins/serialization, Java and download behavior are unchanged.
- Added a synthetic mixed-population example and regressions. The user's actual
  report payload was not available, so the specific cause remains unconfirmed.

## Prior v1.7.36 alignment update

Build: `2026-09-05-CENTERED`; unchanged backend: `1.7.32-SECTIONS`.

Numeric headings and values in the selected-interview section timing table are
now centered. Section names retain left alignment. Calculations, filters and
other report tables are unchanged. This build has not been pushed or published.

## Prior v1.7.35 layout update

Build: `2026-09-05-HISTORYLAYOUT`; unchanged backend: `1.7.32-SECTIONS`.
All changes remain local; nothing is pushed or published.

- Removed the separate unnamed-actor minutes column and subtotal text. That time
  remains part of Active min, with the same actor/event/search filters.
- Right-aligned numeric headings with their values and kept section names on the
  left. Body row labels now use the same light backgrounds as their data cells.
- Matched cell padding and restored the section panel's inner spacing, which a
  more specific workspace rule previously removed. Narrow screens scroll the
  table horizontally instead of squeezing its columns.
- Updated the explanatory text and interactive synthetic example. Timing
  allocation, local indexing and the Java/download code are unchanged.

## Prior v1.7.34 history update

Build: `2026-09-05-HISTORY`; unchanged backend: `1.7.32-SECTIONS`.
All changes remain local; nothing is pushed or published.

- Question timing displays percentages (76.0%, not an ambiguous 0.76 fraction)
  with an explicit heading. Missing values remain unavailable and sorting still
  uses the underlying fractions.
- Literal TSV indexing uses native byte searches, reuses consecutive ID decoding
  and bounded buffers, and reads one 8 MiB chunk ahead. Quoted/multiline parsing,
  fragmented IDs, exact source offsets and memory-limit fallback are retained.
- Cancellation checks after async reads prevent an older selection from
  corrupting a new file's index. Short reads fail explicitly; worker URLs are
  released on file changes. Elapsed indexing time appears in the status line.
- Event history guidance uses full-width plain-language bullets.
- Added per-interview section timing from the loaded raw history, including all
  roles and an explicit included subtotal for events with no responsible actor.
  Actor/event/search filters use precomputed full-chain intervals; periods are
  before/after first completion or all activity. Unmapped activity stays visible.
- Added report-based assignment lookup; multiple matching interviews require
  choosing one. No cross-interview timeline or timing aggregation is implied.
- Embedded the complete question/section map and the configured inactivity
  limit. The timeline's exact-limit boundary now agrees with active timing;
  missing timestamps cannot bridge an artificial raw-history gap.
- Added a preloaded synthetic history example and regression/benchmark tools.
  Java, downloads and exact-folder publication behavior are unchanged.

## Prior v1.7.33 layout update

Build: `2026-09-05-LAYOUT`; unchanged backend: `1.7.32-SECTIONS`.
All changes remain local; nothing is pushed or published.

- Question timing guidance fills the table width and uses seven plain-language
  bullets explaining counts, timed reaches, statistics, filters and ordering.
- Widened the review-list priority column from 88 to 112 px, gave chips a
  minimum width and prevented wrapping. Narrow screens can scroll the table.
- No calculation, filter, download or Java behavior changes.

## Prior v1.7.32 section timing update

Build: `2026-09-05-SECTIONS`; backend: `1.7.32-SECTIONS`.
All changes remain local; nothing is pushed or published.

- Added a Section timing page in the standalone Behaviour report and suite.
  Displays per-section median/P90 minutes, total hours, observed/timed interview
  counts, and time shares; first-pass, correction and all-activity views.
- Uses the existing actor/status/data-value filter intersection. Actor selection
  uses own time; all-actor quantiles sum contributions within each interview.
- Assigns existing active intervals to questionnaire sections before filtering.
  Session/actor boundaries and unknown questions prevent false carry-forward;
  unmapped time stays visible. Automatic validation events cannot move context.
- Keeps unvisited sections with empty quantiles, section search/sorting, filter
  disclosure, timestamp-quality counts and CSV export. Full compact timing
  detail is retained for large reports. Added a source-template synthetic demo.
- Previous secure download, exact-folder and export-progress corrections remain.
  Java behavior is unchanged; only its package version identifiers advance.

## Prior v1.7.31 correction

Build: `2026-09-05-PULLFIX`; backend: `1.7.31-PULLFIX`.
All changes remain local; nothing is pushed or published.

- Preparation now displays queued/preparing/ready states and elapsed time.
  The raw resettable server percentage remains in `r(progress)` and verbose
  diagnostics. Automatic downloads still wait for Completed status.
- Extraction journals use new numbered snapshots instead of repeatedly
  replacing journal.json. Completed snapshots retain sequence and recovery
  state; each snapshot is forced, closed and atomically published.
- Atomic publication retries AccessDeniedException up to five times with
  1.55 seconds of total backoff. This covers journal, data, latest-manifest,
  rollback and downloaded-archive renames. No delete/copy fallback was added.
- Rollback recognizes an original file that remained unchanged after a denied
  move, avoiding a second unnecessary rename. Unresolved recovery still retains
  its material and blocks the next extraction.
- The user's downloaded ZIP can be reused with `suso export extract`; this
  correction does not require another server export. The exact-folder and
  paradata report improvements are retained.

## Prior v1.7.30 correction

Build: `2026-09-05-SAMEFOLDER`; backend: `1.7.30-SAMEFOLDER`.
All changes remain local; nothing is pushed or published.

The v1.7.29 preservation behavior moved an explicitly requested existing
extraction directory into a sibling. That broke scripts resolving questionnaire
and data files relative to their dated output folder. This build honors the
requested destination, stages within it, keeps unrelated files, and preserves
replaced files in internal backups. Handled publication failures roll back;
interrupted or unresolved transactions retain their recovery information.

Added `suso export extract` for reusing a downloaded archive locally. Per-run
version 2 manifests verify archive files within a shared destination. Full
backup runs now stay inside their requested root. The supplied recovery do-file
reuses the user's already downloaded data ZIP and extracted paradata.

## Retained v1.7.29 changes

Build: `2026-09-05-DOWNLOADSAFE`; backend: `1.7.29-DOWNLOADSAFE`.
Retains all v1.7.28 report/correction changes below. Not pushed or published.

- Reuses bounded HTTP clients and polls quick exports sooner. Reports server
  preparation, transfer and extraction times separately.
- Requires verified HTTPS for downloads, rejects downgrade redirects and avoids
  forwarding authorization or write bodies to another origin.
- Retries only transient GET responses, at most twice within the original
  per-hop deadline. Errors retain the existing export JobId for manual recovery.
- Verifies transfer lengths and ZIP structure, computes SHA-256 during receipt,
  and retains an independent prior-file copy before a successful replacement.
- Validates the entire archive in staging before publishing a fresh extraction
  folder. Every extracted file has size/CRC verification and a recorded SHA-256.
- Preserves existing extraction and backup folders. Uses returned actual paths
  when loading paradata; rejects ambiguous input choices and restores the
  previous dataset if import fails.
- Includes `tools/verify_download.py` for later offline integrity checks.

See `DOWNLOAD_SAFETY.md` for changed folder behavior, HTTPS requirements,
timing interpretation and recovery. No end-to-end speedup is claimed before
the user's real server run.

## Retained v1.7.28 changes

Build: `2026-09-04-REVIEWFIX`; Java backend: `1.7.28-REVIEWFIX`.
Based on GitHub commit `0c41c81fa192b438b86ddb6db377942bd1e40104`.
These changes have not been pushed or published.

## Corrected calculations and data checks

- Enumerator fast-answer and night-work shares now follow the live thresholds
  used in the interview review. Peer reference calculations use the same context.
- The default review queue includes qualifying findings from secondary actors.
  An interview is counted once; evidence stays with its actor. Findings from
  different actors are not combined to manufacture a stronger priority tier.
- `misscodes()` passes through the whole suite, including removal final-state
  checks and Data QC. An explicit numeric list replaces the default list.
- Removal trigger candidates must fall within the configured time window.
  A distant later answer is no longer retained as if it explained a removal.
- Reduced paradata exports without a question-variable column can still produce
  removal inventories, with unavailable trigger context left unexplained.
- Single-select validation uses complete questionnaire option lists, including
  lists longer than 60 values. Incomplete metadata fails explicitly instead of
  reporting a misleading zero-error result.
- Live fast-answer cutoffs are limited to exact half-second steps from 0.5 to
  10 seconds, matching the stored histogram. Unsupported cutoffs are rejected.
  Lite reports retain their disclosed build-time timing settings.

## Revised paradata report

- A searchable, paginated interview queue sits beside the selected interview's
  evidence panel. Review actors and primary-actor context are distinguished.
- Direct navigation exposes questions, enumerators, removals and event history
  without scrolling through every chart. Existing CSV exports remain available.
- The suite mirrors the applicable actor, status and variable filters across
  tabs. Scope exceptions are named; Data QC does not imply unsupported joint
  filtering when only separate marginal results are available.
- Native buttons, keyboard tab navigation, focus return, responsive tables and
  expandable details improve access. Embedded reports share the outer page's
  scrolling and suppress repeated mastheads.
- Removal links include histories outside the compact prioritization subset.
  Priority and evidence copy describe screening signals, not proof of misconduct.

## Backend and distribution

- Restored the missing questionnaire parser and complete bridge source from
  the shipped binary, preserving its parser behavior and SFI signatures.
- HTTP timeouts cover the complete response body, with cancellation and cleanup.
  A failed download preserves an existing destination. The configured limit is
  applied per HTTP hop, including redirected requests.
- Source builds retain the shipped redirect and ZIP-containment protections.
  Reproducible Java packaging and checksum-validated recovery are included.
- Root/install files, the SSC archive and base64 recovery payload are generated
  from the same canonical files. The local ZIP includes a SHA-256 manifest.

## Try it

See `README.md` for local setup, `examples/README.md` for the interactive preview
and real Stata example, and `TEST_RESULTS.md` for validation limits. The preview
uses the actual revised templates with illustrative synthetic payloads; its
numbers are not results calculated by Stata from the supplied raw fixture.
