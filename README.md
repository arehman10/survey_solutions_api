# suso — Survey Solutions REST API client for Stata

**The World Bank · DEC · Enterprise Surveys**

**Local review build v1.7.36 — not published.** Start with the local review
instructions below and `examples/example.do`. The GitHub installation command
still downloads the published version, not these candidate changes.

`suso` is a safety-first Stata command that wraps the World Bank **Survey Solutions**
REST API. A small Java backend (`suso.jar`) performs the authenticated HTTPS calls
(every verb, including `PATCH`/`DELETE`), list endpoints load **directly into a Stata
dataset**, and destructive operations are guarded at two independent layers.

---

## What you get

```
suso.ado      Stata frontend (commands, options, safety, pagination)
suso.sthlp    Stata help file       (help suso)
suso.jar      Java backend          (HTTP + JSON, no dependencies)
src/          Complete Java source  (including HTTP, ZIP and file publication)
build.sh      Rebuild the jar       (macOS / Linux)
build.bat     Rebuild the jar       (Windows)
```

## Requirements

- Stata with Java integration enabled, running on a **Java 11+** runtime.
  Verify with `suso doctor` (it prints the JVM version and flags anything older).
  Java 11+ is required because Survey Solutions uses `PATCH` extensively
  (approve / reject / assign / archive / change-quantity / audio / criticality).
- `suso.jar` reachable on the adopath, or set explicitly with `suso config , jar()`.

## Install

The easy way, straight from GitHub inside Stata:

```stata
net install suso, from("https://raw.githubusercontent.com/arehman10/survey_solutions_api/main/install") replace
```

This installs `suso.ado`, `suso.sthlp` and `suso.jar` in one step. If you are upgrading and Stata
complains or keeps running the old version, run `ado uninstall suso` and `discard` first.

Alternatively, install by hand: copy the three files to your Stata `PLUS` or `PERSONAL` folder (find them in Stata with
`display c(sysdir_plus)` and `display c(sysdir_personal)`):

```
suso.ado    -> e.g.  .../ado/plus/s/suso.ado
suso.sthlp  -> e.g.  .../ado/plus/s/suso.sthlp
suso.jar    -> same folder, OR anywhere, then:  suso config , jar("C:/path/suso.jar")
```

Then in Stata:

```stata
suso config , server(https://decpm11-surveys.worldbank.org) workspace(srilankainf) user(myapiuser)
suso doctor          // environment + Java check
suso ping            // connectivity + auth check
```

The password can be typed (`password()`), or — better — exported as the
`SUSO_PASSWORD` environment variable before launching Stata, so it never enters your
command history. Configuration is held in this Stata session only and is **never written
to disk**. Survey Solutions' convention is to create an **API user** account and use
Basic auth (the default; `auth(bearer) token()` is also supported).

## Quick start

```stata
suso assignment list , all                       // -> dataset of assignments
suso interview list   , status(Completed) all    // -> dataset of interviews
suso export start , type(STATA) questionnaire(<guid>) qver(3) istatus(ApprovedBySupervisor)
suso export status   , id(`=r(jobid)')
suso export download , id(`=r(jobid)') saving(ises.zip) replace
suso export get , type(STATA) saving(ises.zip) unzipw("pw") unzipto("data") replace  // one-shot
suso interview reject , id(<uuid>) comment("GPS off-square; please revisit")
suso paradata get                                // pull the event log ...
suso paradata flags                              // ... and flag suspicious interviews
```

List commands replace the current dataset and return `r(nobs)`, `r(nvars)` and (when the
server reports it) `r(totalcount)`. ISO-8601 date columns are auto-converted to Stata
`%tc`. Single-object commands flatten JSON fields into `r()` (e.g. `r(jobid)`,
`r(exportstatus)`, `r(canbedeleted)`). All commands return `r(http)`.

## Local review build: v1.7.36

Question timing now displays percentages with an explicit heading: a share
of 0.76 appears as **76.0%**. The Event history instructions use full-width
bullets, and the local file indexer avoids repeated ID decoding and reads one
bounded chunk ahead. The file stays in your browser; nothing is uploaded.
Selecting a local-drive copy can reduce network-drive delays.

Event history also shows **section timing for the selected interview**. Time
from events without a named actor remains included in **Active min**. Numeric
headings and values are centered; section names align to the left. Actor, event-type and text filters apply after intervals are measured
on the complete history, so hidden events cannot stretch a gap. Choose all
activity, before first completion, or later work. This raw-history estimate
includes all roles; it can differ from the survey-wide fieldwork timing page.

Enter an interview ID or `assignment: 12345`. Assignment lookup uses the
interviews included in this report and asks you to choose one when several
share an assignment. It never combines their event timelines.
Open `examples/preview/history-timing-example.html` for an interactive synthetic
example. The included Java backend remains `1.7.32-SECTIONS`.

The Behaviour report now has a **Section timing** page. Supply `qx()` for
questionnaire section titles and `data()` with `filters()` for data-based
filter controls. Existing report and suite commands work unchanged. The page
shows total active hours, median/P90 minutes per interview, counts of observed
and timed interviews, and each section's share of scoped time. Choose first
pass, later corrections, or all activity. Actor, status and variable/value
filters apply together; an actor selection uses only that contributor's time.
Search/sort sections and download the displayed table as CSV. Unmapped activity
stays visible, and sections with no timing have no invented zero-minute median.
Open `examples/preview/section-timing-example.html` for a working synthetic
example. `examples/preview/paradata-example.html` shows the full suite.

Section timing uses the existing active intervals, assigned on the full event
stream before filters. The interval ending at an answer, removal or comment
belongs to that question's top-level section. Other events retain the previous
section only within the same actor/session. An unknown question resets that
context to Unmapped. Contributor times are summed within each interview before
quantiles are calculated; P90 uses the nearest rank among positive durations.
Section titles shared in the questionnaire metadata are grouped together.
`vars()` limits question/removal detail, so this page keeps the whole questionnaire.
The full section payload remains available above `litecap()`.

The previous download and folder corrections are retained:

Export preparation now shows its state and elapsed time instead of an
unreliable overall percentage. Survey Solutions reuses its progress field
across preparation stages, so it can reach 100 and reset while still running.
`suso export status, id(...) verbose` shows the raw server percentage for
diagnostics; `r(progress)` remains unchanged. Ready for download means server
preparation has completed, not that the file is already saved locally.

This build also addresses the reported Windows extraction-journal failure.
Journal updates use new numbered snapshots, and atomic renames briefly retry
access-denied errors. Persistent permission problems still stop safely.
Install both the ADO and JAR and restart Stata; `suso doctor, strict` checks
that the v1.7.32-SECTIONS backend is loaded.
For the failed extraction of an already downloaded `ises_${folder_name}.zip`,
run `examples/retry_existing_zip.do` after your usual configuration. It extracts
locally into `${data_server}` and checks the data/questionnaire paths; it does
not request a new export or replace the current dataset.

This build retains the paradata calculation corrections and compact review
workspace, and adds reusable HTTP connections and verified download/extraction
publication. Read `DOWNLOAD_SAFETY.md` before the local run: previous archives
are retained when replaced, extraction honors the requested folder and backs
up files it replaces inside that folder, and downloads require verified HTTPS.
It has not been pushed or published. Version 1.7.30 corrects the v1.7.29
directory relocation that broke relative questionnaire/data paths.

If your v1.7.29 download already succeeded, `examples/recover_existing_pull.do`
reuses the existing data ZIP and extracted paradata from the supplied log.
`suso export extract, file(...) unzipto(...)` extracts locally without creating
another export or replacing the dataset in memory.
See `TEST_RESULTS.md` for the checks actually run and the remaining Stata/SFI
acceptance checks.

To try it without replacing your installed package, open a fresh Stata session
and put this extracted package first on that session's adopath:

```stata
cd "C:/path/to/extracted/package"
adopath ++ "C:/path/to/extracted/package/install"
suso config , jar("C:/path/to/extracted/package/install/suso.jar")
which suso
suso version
suso doctor
```

Use the included synthetic example before running your survey. The `examples`
folder contains a ready-to-open report and a do-file to regenerate a small
example in Stata. Its data are invented and are not survey findings. A fresh
Stata session is important when changing the Java backend, because Java classes
from an earlier version may remain loaded in an existing session.

For your own files, use the same paradata commands as before:

```stata
suso paradata load , file("C:/survey/paradata.tab")
suso paradata suite , qx("C:/survey/questionnaire.html") ///
    data("C:/survey/main.dta") filters(lf_responsive) ///
    saving("C:/survey/qc_suite_review.html") replace
```

If your survey uses special numeric missing codes, specify the same intended
`misscodes()` list for the whole suite; it now applies consistently to Data QC
and removal final-state checks. Explicit lists replace the default list.

## Paradata analysis (timing + behaviour QC)

`suso paradata` turns the Survey Solutions event log into fieldwork-quality
intelligence, fully vectorized for multi-million-row files:

```stata
suso paradata get                          // export type(Paradata) -> poll -> download -> unzip -> load
suso paradata load , file("para.zip")      // or reload a saved export offline (unzipw() if protected)
suso config , exportpw("...")              // set the export-archive password once; all unzips use it
suso paradata report , saving("qc.html")  // interactive one-page QC report: filter by enumerator,
                                           //   search questions, adjust night window + all flag thresholds live
suso paradata flags                        // per-interview red flags + interviewer league table
suso paradata skips , qx("qx.html") messages("review.txt") html("review.html")  // supervisor action list: which gate
suso paradata check , qx("qx.html") data("main.dta") html("qc.html") status(approved)  // audit the skip logic
suso paradata suite , qx("qx.html") data("main.dta") saving("qc_suite.html")  // ALL THREE in one tabbed HTML
suso paradata check if lf_responsive==1, qx("qx.html") data("main.dta") ///
    filters(lf_responsive region) html("qc.html")   // restrict by any expression; live variable filters
                                           //   answers on disabled questions, item nonresponse, bad values
                                           //   was flipped, what it erased, what to do - email-ready
suso paradata timing , by(question)        // slowest questions first (instrument diagnostics)
suso paradata skips                        // gate flips: skip-triggered answer-removal cascades
```

`timing` collapses events to one row per interview (or question/interviewer):
active time with inter-event gaps capped at `gapmins(30)` and Paused→Resumed
intervals zeroed, work sessions, median/p90 seconds per answer, fast-answer
share (< `fastsecs(2)`), night-work share (22:00–05:59 device-local time),
answer churn and pace. Supervisor/HQ events are excluded from timing when the
`role` column identifies interviewers (counts like rejections still use all
events). `flags` raises six screening flags per interview — **S** sustained
speeding, **B** answer bursts, **T** too short, **N** night work, **C** answer
churn, **Z** robust duration outlier (modified z on log active time) — prints
the worst offenders and an interviewer league table, and leaves a mergeable
one-row-per-interview dataset in memory. Both paradata layouts are handled
(`timestamp_utc`/`tz_offset` and the legacy `timestamp`/`offset`). Flags are
screening signals for review, not proof of fabrication.

`skips` is the skip check paradata supports: SuSo enforces enablement at
capture time, so instead of "answered while disabled" it detects **gate
flips** — runs of ≥ `cascade(3)` consecutive `AnswerRemoved` events within
`window(60)` seconds of an `AnswerSet` — names the trigger variable, ranks
the gates wiping the most answers, and merges 1:1 with the `flags` table.

## Safety design (destructive operations)

Defense in depth — the Stata layer requires explicit opt-in, and the Java backend
independently refuses any destructive request unless the Stata layer set its internal
allow-flag. A bug on either side cannot silently destroy data.

| Operation | Guard |
|---|---|
| `interview delete`, `export cancel`, `assignment archive`, `user archive`, `workspace disable` | require `, confirm` |
| `workspace delete` | retype the exact name in `iknowthis(name)`, **plus** an automatic pre-flight `status` check that refuses unless the server says the workspace can be deleted (override with `force`) |

Every destructive action is appended to an audit log
(default `<PERSONAL>/suso_audit.log`; change with `suso config , auditfile()`),
recording timestamp, user, server/workspace, action, target and HTTP status.

Pagination is automatic (`, all`) but capped at `SUSO_MAXROWS` rows (default 100,000) to
avoid accidental mega-pulls; raise it with `suso config , maxrows()` or use
`suso export` for bulk data.

## SSL / proxy on the WBG corporate network

**Preferred:** import the corporate root CA into the trust store of the Java runtime that
Stata uses. Find that runtime with `suso doctor` (it prints *Java home*), then:

```bash
keytool -importcert -alias wbg-root -file wbg-root.crt -cacerts
# (older layout: -keystore "<java.home>/lib/security/cacerts" -storepass changeit)
```

**Proxy:**

```stata
suso config , proxyhost(proxy.worldbank.org) proxyport(8080)
suso config , proxyhost(...) proxyport(...) proxyuser(...) proxypass(...)
```

**Escape hatch (use with care):** `suso config , insecure` disables TLS certificate and
hostname verification for the session. Each request then prints a warning. Prefer
importing the CA over running insecure.

## `suso raw` — reach anything

```stata
suso raw /api/v1/settings/globalnotice                          // GET, flatten to r()
suso raw /api/v1/assignments , query(Limit=5&Offset=0) todata arraykey(Assignments)
suso raw /api/v1/interviews/<uuid> , method(DELETE) allowdestructive
```

## Rebuilding the jar from source

A prebuilt `suso.jar` ships in the root and `install` folders. The complete
backend source is in `src`. A rebuild needs a JDK 11+ and your Stata's
`sfi-api.jar` (find your Stata folder with `display c(sysdir_stata)`):

```bash
./build.sh /path/to/sfi-api.jar           # macOS / Linux
build.bat  "C:\Program Files\Stata18\...\sfi-api.jar"   # Windows
```

The build writes `dist/suso.jar`, compiled to Java 11 bytecode with no external
runtime dependencies. It contains only `org/worldbank/suso/*` and relies on
Stata's own `com.stata.sfi` at runtime. Compile-only test substitutes are never
included in the distribution JAR. The base64 recovery script validates
`suso.jar.sha256` before replacing a JAR; recovery reconstructs the same release
binary and is not a source rebuild.

## Notes

- The REST interview-list endpoints are deprecated by Survey Solutions; for very large
  interview pulls, GraphQL or `suso export` is recommended. `suso` still supports them
  and prints a one-line reminder.
- Workspace-management endpoints are server-level on a standard Survey Solutions
  deployment, so workspace commands default to the server root. If your server scopes
  them under the workspace, add `, usews`.
- Questionnaire identities are passed as separate `questionnaire(<guid>)` and `qver(#)`
  options; the backend assembles the `guid$version` form internally.


## Citation

If `suso` supports your research or fieldwork, please cite it:

> Rehman, A. U. (2026). *suso: A Survey Solutions API client for Stata* (v1.6.0)
> \[Computer software]. https://github.com/arehman10/survey_solutions_api

## Contributing

Issues and pull requests are welcome. For backend changes, please rebuild the jar from
`src/` and confirm `suso doctor` / `suso ping` pass against a test workspace.

## Acknowledgments

Thanks to [Fahad Mirza](https://github.com/fahad-mirza) (World Bank / CERP) for his
insights and guidance, and for his self-contained Stata tooling
([sparkta](https://github.com/fahad-mirza/sparkta_stata),
[wordcloud2](https://github.com/fahad-mirza/wordcloud2_stata)), which helped shape the
design of this package.

## License

[MIT](LICENSE) © 2026 Attique Ur Rehman (The World Bank, Development Economics).
