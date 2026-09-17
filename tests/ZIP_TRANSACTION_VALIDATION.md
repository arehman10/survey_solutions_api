# ZIP extraction validation

The extractor validates the complete archive before publishing any archive files.
It then publishes into the **exact requested directory**, including an existing
date folder. Files absent from the new archive remain in place. Existing files
that the archive replaces are retained at their original relative paths inside
`<destination>/.suso-backups/<run-id>/`, returned in `Result.backupDir`. The source
archive is opened read-only, retained, and cannot be an extraction target. Existing
destination directory permissions remain unchanged; newly created files are private
on POSIX systems.

`Result.manifest` identifies `.suso-manifests/<run-id>.json`; `.suso-manifest.json`
contains the same bytes as the latest successful run's manifest. Earlier per-run
manifests and backups remain available. `Result.bytes` counts extracted file bytes.
The manifest uses format `suso-extraction-manifest`, version 2, scope `archive-files`, archive basename,
completion UTC timestamp, `file_count`, total `bytes`, and a `files` array containing
relative `path`, `bytes`, `crc32`, and `sha256`. The inventory describes files from
that archive, not unrelated files or the entire combined destination. The manifest
is not included in the archive file count. Files and the manifest are flushed to the
filesystem before publication.

Publication is journaled and guarded by a per-folder lock. A normal publication
failure restores replaced files, removes newly published files and keeps the last
successful manifest. Original-file backups remain available after rollback. If a
restore itself fails, the error identifies the retained transaction directory,
file and byte counts are `-1` (unknown), and the lock stays in place to block another
extraction until recovery. The lock is an atomically created directory, so a
process exit does not silently remove the pending-state marker. This is
rollback for caught publication errors, not a promise of an atomic multi-file view
to other programs, automated crash recovery, or protection from failing storage
hardware. Pending transactions must not be silently bypassed.
An extraction blocked by an existing lock or transaction also reports file and
byte counts as `-1` and returns the pending state location. It cannot assert that
the destination contains zero partial changes from an earlier interrupted run.

The v1.7.31 correction writes immutable version-2 journal snapshots named
`journal-00000000000000000001.json`, then increasing sequence numbers, inside each
transaction directory. Every snapshot is flushed and closed before an atomic
rename to a new filename; no existing journal or mutable latest pointer is
replaced. For manual recovery, select the greatest numbered complete `.json`
snapshot and check its embedded `sequence`. A `.next` file is uncommitted and must
not supersede that snapshot. A malformed complete snapshot needs inspection, not
silent fallback to older state. Existing v1.7.30 `journal.json` transactions still
block new extraction; the new build does not automatically recover them.

Journal, file and manifest publication retain atomic moves. A bounded retry handles
temporary `AccessDeniedException` failures without deleting the target or falling
back to a non-atomic copy. If a rejected file move left the target unchanged,
rollback verifies that original state and avoids a second unnecessary rename.
Persistent failure still stops and rolls back or retains explicit pending state.
The observed Windows `O:` journal failure is covered by injected denial cases;
the actual drive and its locking behavior were not available for this test.

POSIX systems create staging directories with mode 0700 and files with mode 0600.
Other filesystems use their inherited permissions. Windows ACL behavior and Stata
integration require testing in the user's Windows/Stata environment.

## Focused regression command

Compile the new production classes and standalone test with JDK 11 or newer:

```sh
java -m jdk.compiler/com.sun.tools.javac.Main --release 11 -Xlint:all \
  -d build/zip-tests src/org/worldbank/suso/Zip.java \
  src/org/worldbank/suso/ZipPublisher.java \
  src/org/worldbank/suso/AtomicFiles.java \
  src/org/worldbank/suso/Json.java \
  tests/java/org/worldbank/suso/ZipTransactionTest.java
java -cp build/zip-tests org.worldbank.suso.ZipTransactionTest
```

Or compile the test against the release JAR and put that JAR first on the runtime
classpath. No Stata, server, passwords, external fixture generator, or network is
required. Passwords in the embedded Info-ZIP fixtures are test strings only.

**Executed on Java 17/Linux: 304 assertions passed**, with production and test
sources compiled together using Java 11 source/bytecode compatibility. The
earlier fresh-folder extractor passed 133 assertions and v1.7.30 passed 224;
the current suite retains its archive parsing cases and adds the publication
tests below.

Coverage includes:

- A corrupt last entry leaves every old destination file unchanged, reports zero
  extracted files, and leaves neither a final folder nor staging files for a new
  destination; source archive bytes remain unchanged on success and failure.
- Fresh and existing destinations, empty folders, empty files and directories,
  three-file manifest inventory, all file sizes/CRC/SHA-256 values, preserved old
  directory permissions and private new files.
- A date folder containing the source ZIP, an old questionnaire and survey data,
  and unrelated analysis files: exact-path replacements, recoverable old copies,
  a subsequent paradata export in the same folder, retained survey files and
  backup history, separate per-run manifests and an updated latest manifest.
- Deterministic failures after a replacement and a newly created file have been
  published; restoration of the first file, removal of the new file, preservation
  of unrelated files and old manifest, retained backups, and a successful retry.
- A failure while publishing the latest manifest rolls back data and its per-run
  manifest. A second failure while restoring a file retains the journal, original
  backup and lock, reports the pending transaction path and blocks another run.
  That blocked retry reports unknown counts and preserves the pending state.
- A simulated provider denies any journal target reuse: extraction completes with
  distinct snapshots, increasing filename/content sequences, every prior snapshot
  unchanged and every transaction phase recorded.
- A one-time journal failure after actual data publication restores original files
  and allows retry. Persistent journal failure retains complete recovery snapshots,
  original backups and lock, reports unknown counts, and blocks another extraction.
  An incomplete `.next` with a higher number does not supersede the latest complete
  snapshot.
- An atomic file move denied before altering its target does not trigger a second
  rename of that unchanged original. Earlier published files are still restored;
  both existing-file and new-file rejection cases complete rollback and release
  the lock.
- Existing file/directory collisions, an entry targeting the source ZIP, reserved
  internal names and pre-existing pending extraction state, with or without a
  lock; pending-state errors identify its location and report unknown counts.
- Stored and deflated Info-ZIP ZipCrypto fixtures, correct/wrong/missing passwords,
  ZIP64 end/entry/local metadata using a small-content ZIP64 fixture.
- Traversal, absolute paths, NTFS alternate streams, Windows device/alias names,
  duplicate and case/Unicode-equivalent paths, file/directory collisions,
  symlink entries, symlink destination/ancestors, and rejection of an existing
  symlink at a target path without changing the link or its external target.
- Local/central CRC/size mismatches, descriptor CRC/size mismatches, directory
  data/CRC, ZIP64 locator/record metadata, incomplete archives, and an end record
  embedded in a valid ZIP comment that previously could hide all real entries.

The previous version's root-level integrity verifier also checked its manifest and
all 57,000,057 bytes of a generated paradata benchmark extraction. That run is
historical evidence, not a rerun of the current exact-folder publication flow.

## Extraction benchmark

`ZipExtractionBenchmark.java` can run with either baseline or revised classes
first on its classpath. Arguments are: encrypted archive, output parent, test
password, expected plaintext SHA-256. It runs one warm-up and five measured
extractions, independently checks the complete plaintext SHA-256 after each run,
and removes each extracted folder after verification. Verification/removal time
is outside the extraction timer.

For the earlier fresh-folder implementation, a synthetic 600,000-row paradata TSV (57,000,057 bytes), compressed and encrypted
by Info-ZIP into 8,463,342 bytes, measured:

| Extractor | Median of five measured runs |
| --- | ---: |
| Baseline 1.7.28 JAR | 0.1684 seconds |
| Earlier fresh-folder extractor, structural checks included | 0.2105 seconds |

All plaintext hashes matched. This is a local warm-cache benchmark, not a server,
network, Windows-disk, or end-to-end Survey Solutions download benchmark. The added
transactional validation, manifest hashing, and file flushes cost about 42 ms in
this fixture; they are safety work, not a claimed extraction acceleration. The
old decryption stream already performed bulk reads. No speculative byte-at-a-time
"optimization" was introduced.

The fixed archive/plaintext hashes are generated from synthetic data only. Actual
exports larger than 4 GiB, production Survey Solutions ZIP variants, filesystem
crashes, and concurrent modification of a parent directory by another process were
not exercised. ZIP64 metadata parsing is covered by the small synthetic fixture.
