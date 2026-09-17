# Requested-folder and offline-recovery checks

`python3 tests/folder_flow_source_regression.py` checks six source-wiring
conditions: offline export extraction, extraction returns, backup runs inside
the requested root, correct backup returns, and the existing paradata `dir()`
forwarding and import rollback, and propagation of backup locations. These checks do not execute Stata or establish
Java filesystem behavior.

`python3 tests/download_flow_source_regression.py` also covers existing download
orchestration. The folder change preserves those checks.

In a fresh licensed Stata session, configure the JAR from this package and run:

```stata
do "tests/download_flow_smoke.do"
do "tests/folder_flow_smoke.do"
```

The first script checks backup directories, preflight errors and preservation of
the active dataset on invalid paradata import. The second checks the public
`suso export extract` command with no server configured, a pre-existing output
folder, nested questionnaire-preview files, unrelated existing files, repeated
extraction, return values and preservation of the active dataset. Its small ZIP
fixture contains text only. The resulting temporary folder is printed and kept
for inspection. Both scripts restore the caller's dataset and server setting.

These Stata scripts have not been run in the development environment because a
licensed Stata executable and its SFI runtime are unavailable. Separate Java
transaction tests exercise archive validation, replacement backups and rollback.

The offline recovery interface is:

```stata
suso export extract, file("already-downloaded.zip") unzipto("requested-folder")
```

`unzipw()` is optional and defaults to the session's configured export password.
The original ZIP is retained. No export is created and no dataset is imported.
`r(unzipdir)` is the exact extraction root; `r(manifest)` identifies that
extraction's integrity manifest; `r(unzip_backup)` identifies preserved replaced
files when present. Backup operations return their requested root
as `r(root)` and their timestamped child run folder as `r(dir)`.
