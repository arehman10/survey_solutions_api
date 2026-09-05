# Verified downloads in the requested folder — local v1.7.31 candidate

This candidate retains the revised paradata report. It has not been pushed to
GitHub. Use the local installation instructions in `README.md` in a fresh Stata
session. Your existing server configuration and export commands still apply,
subject to the file-preservation and HTTPS behavior below. Version 1.7.30
corrects v1.7.29's relocation of existing extraction destinations into siblings.
An explicit `unzipto()` now means exactly that directory.

## Where time is spent

Version 1.7.31 corrects the preparation display. Normal polling shows queued,
preparing, or ready for download, together with elapsed time. It does not invent
a smooth overall percentage from the server's resettable progress value. Use
`suso export status, id(...) verbose` for the raw server diagnostic;
`r(progress)` is unchanged. File downloading starts after preparation completes.

The [official export handler](https://github.com/surveysolutions/surveysolutions/blob/b60de19d841703284c312ca783c9718301bbb158/src/Services/Export/WB.Services.Export/ExportProcessHandlers/Implementation/ExportProcessHandler.cs)
feeds multiple stages into the same progress field, and
[event preparation](https://github.com/surveysolutions/surveysolutions/blob/b60de19d841703284c312ca783c9718301bbb158/src/Services/Export/WB.Services.Export/Events/EventsProcessor.cs)
can report 100 before export-file creation. The public endpoint does not expose
a stage field from which a reliable overall percentage could be calculated.
These sources explain a reset; the deployed version of the user's server was
not inspected.

This build also addresses the user's extraction failure while replacing
`journal.json` on Windows. Every journal update is now a new numbered JSON
snapshot, atomically published after forcing and closing it. Recovery uses
the highest complete numbered snapshot; unfinished `.next` files are not
committed snapshots. No mutable latest-journal pointer is required.
Atomic renames retry access-denied errors at most five times, waiting a total
of 1.55 seconds. Data, latest-manifest, rollback and archive publication use
the same bounded retry. Persistent permission failures still stop; no prior
target is deleted to make a rename succeed. Rollback skips replacement when
the original file already remains unchanged. The error does not establish
the specific cause on the user's drive, and Windows/SMB execution is untested.

An export has three separate stages: the server prepares the archive, the
client transfers it, and the client verifies/extracts it. Reusing HTTP clients
allows connections to be reused across requests. Quick jobs are checked after
1, 2 and 5 seconds before settling at the requested polling interval. These
changes reduce connection setup and avoid a fixed ten-second first wait; they
do not increase your server's export capacity or internet bandwidth.

The commands report preparation, download and extraction time separately.
`r(prepare_seconds)` includes API and polling time, `r(download_seconds)` covers
the transfer operation, and `r(unzip_seconds)` covers verification/extraction.
Preparation and extraction measurements use Stata's whole-second clock.
The preparation budget is checked between API calls; a call already in flight
is bounded separately by `readtimeout()`.

The HTTP connection reuse follows Java's supported immutable-client model.
See the [Java 11 HttpClient documentation](https://docs.oracle.com/en/java/javase/11/docs/api/java.net.http/java/net/http/HttpClient.html).
Proxy-authenticated clients are not cached. No request passwords or tokens are
stored in the shared client cache.

## How the files are protected

1. A download streams to a temporary file beside the intended destination.
   Its bytes are hashed while they arrive. Unexpected status codes, empty or
   truncated downloads, and structurally invalid ZIP archives are rejected.
2. A successful replacement preserves an independent copy of the previous file
   before publishing the new one. `r(backup)` reports that copy. Failed transfers
   leave the existing file intact. If atomic replacement is unsupported, use
   a new `saving()` filename; the existing file is not replaced using a weaker
   fallback. Preserving an existing large file takes additional disk space and
   copying time.
3. Extraction takes place in private staging inside the requested folder.
   Every archive file must pass size and CRC checks before installation;
   SHA-256 hashes are recorded. A corrupt later archive entry cannot cause
   earlier entries to be installed.

**Files are installed into the exact requested directory.** For example,
`unzipto("${data_server}")` keeps data and `Questionnaire/Preview/...` under that
dated folder, so relative report paths work. Unrelated files remain in place.
Prior versions of replaced files are kept under `.suso-backups` inside the same
directory, with the run's backup path returned in `r(unzip_backup)`. The original
ZIP is retained and protected from being overwritten by its own contents.

Each file is published atomically. A handled publication failure triggers
rollback of previously installed files. An interruption or unresolved rollback
retains recovery material and a blocking transaction marker; the error reports
its location. Do not remove that marker or backup material before recovery.
This does not provide an atomic snapshot of the whole folder to other programs
reading while an extraction is installing its files.

Full-workspace `suso backup` allocates a fresh child directory inside the requested
root for each run. `r(root)` records that root and `r(dir)` the child directory.
Previously saved questionnaire and workspace snapshots are retained.
`backup_status.txt` remains INCOMPLETE until the run finishes, then records
COMPLETE or PARTIAL and the failure count. `r(complete)` reports whether all
requested operations finished without a reported failure.

Archive paths that escape the destination, symbolic links and conflicting file
names are rejected. This includes names that would collide on Windows even if
the archive was downloaded on another operating system.

Downloads require HTTPS with certificate and hostname verification. An
HTTPS-to-HTTP redirect is rejected, and authorization is not forwarded to an
unrelated origin. `insecure` cannot be used for file downloads. If a corporate
proxy requires its certificate authority, install that CA in Stata's Java trust
store as described in the README. There is no silent TLS fallback.

Only transient GET responses are eligible for bounded automatic retries.
Timeout, security, local-disk and permission failures are reported for you to
resolve. POST/PATCH/DELETE requests are not automatically repeated. If a
completed export cannot be downloaded, the error gives its JobId and a command
to retry that existing job without creating another export.

## Check a completed pull

For example, after your normal server configuration:

```stata
suso export get, type(STATA) saving("C:/survey/pull_20260905.zip") ///
    unzipto("C:/survey/pull_20260905")
return list
```

Add your usual questionnaire, version, status and date filters. The sample
paths are new paths; no `replace` is needed. To deliberately replace an archive,
add `replace`; the previous copy's path is then reported in `r(backup)`.

Each completed extraction records the names, byte counts and SHA-256 hashes of
that archive's files. `r(manifest)` returns its per-run record under
`.suso-manifests`; `.suso-manifest.json` is the latest record. Later, check the
latest extraction for missing or modified files offline:

```sh
python tools/verify_download.py "C:/survey/pull_20260905"
```

You may also pass the exact `r(manifest)` file path to check a particular run.
Version 2 manifests cover the recorded archive files; unrelated ZIPs, paradata,
reports and other files in the same folder are left alone and do not cause a
false verification failure. Intentional changes to a recorded file are still
reported. Legacy version 1 manifests continue to verify the entire isolated
folder. The downloaded archive's SHA-256 is returned in `r(sha256)`; on Windows,
`certutil -hashfile FILE SHA256` can independently calculate it for comparison.

## Recover the already completed pull

After installing v1.7.30 in a fresh Stata session and applying your usual
configuration, run:

```stata
cd "${data_server}"
suso export extract, file("ises_${folder_name}.zip") unzipto("${data_server}")
confirm file "Questionnaire/Preview/English Global_informal2026.html"
confirm file "Global_informal2026.dta"
```

This is local extraction. It neither contacts the server nor changes the dataset
in memory. It uses the configured export password when required; no password is
included in this package. `examples/recover_existing_pull.do` then loads the
already extracted paradata from the supplied log and reruns the report with
the same questionnaire/data paths. No second data or paradata export is needed.

These checks establish the integrity of the files received and later retained.
They do not prove that the server included every record: questionnaire/version,
status/date filters and the server's export contents still determine the data
scope. A local manifest is an integrity record, not a digital signature. No
client can guarantee against all hardware failures or concurrent external edits.

## Validation status

See `TEST_RESULTS.md` for the executed failure tests and performance probe.
No licensed Stata runtime was available here; the v1.7.30 end-to-end run remains
necessary. The earlier user log confirms successful v1.7.29 transfers and
paradata import, and exposes the directory regression addressed here. Offline
Stata smoke tests are `tests/download_flow_smoke.do` and
`tests/folder_flow_smoke.do`, run from the extracted package root.
