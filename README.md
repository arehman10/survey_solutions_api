# suso — Survey Solutions REST API client for Stata

**The World Bank · DEC · Enterprise Surveys**

`suso` is a safety-first Stata command that wraps the World Bank **Survey Solutions**
REST API. A small Java backend (`suso.jar`) performs the authenticated HTTPS calls
(every verb, including `PATCH`/`DELETE`), list endpoints load **directly into a Stata
dataset**, and destructive operations are guarded at two independent layers. It is built
for the WBES / B-READY / ISES fieldwork workflow and has **zero third-party dependencies**.

---

## What you get

```
suso.ado      Stata frontend (commands, options, safety, pagination)
suso.sthlp    Stata help file       (help suso)
suso.jar      Java backend          (HTTP + JSON, no dependencies)
src/          Java source           (Json.java, Http.java, Stata.java)
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

A prebuilt `dist/suso.jar` ships with the package and works on any Stata with a Java 11+
runtime. Rebuild **only** if the prebuilt jar errors at runtime (e.g. a
`NoSuchMethodError`, which would indicate a different SFI on your Stata). You need a JDK
11+ and your Stata's `sfi-api.jar` (find your Stata folder with `display c(sysdir_stata)`):

```bash
./build.sh /path/to/sfi-api.jar           # macOS / Linux
build.bat  "C:\Program Files\Stata18\...\sfi-api.jar"   # Windows
```

The jar is compiled to Java 11 bytecode with no external dependencies and contains only
`org/worldbank/suso/*` (it relies on Stata's own `com.stata.sfi` at runtime).

## Notes

- The REST interview-list endpoints are deprecated by Survey Solutions; for very large
  interview pulls, GraphQL or `suso export` is recommended. `suso` still supports them
  and prints a one-line reminder.
- Workspace-management endpoints are server-level on a standard Survey Solutions
  deployment, so workspace commands default to the server root. If your server scopes
  them under the workspace, add `, usews`.
- Questionnaire identities are passed as separate `questionnaire(<guid>)` and `qver(#)`
  options; the backend assembles the `guid$version` form internally.

## Architecture (one line)

`suso.ado` sets `SUSO_*` globals → `javacall org.worldbank.suso.Stata run` → `Http`
(java.net.http) executes → `Json` parses → results are written back into the Stata
dataset / `r()` via the SFI, and the password global is scrubbed after every call.
