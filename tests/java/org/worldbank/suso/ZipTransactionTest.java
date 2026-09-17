package org.worldbank.suso;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Focused whole-archive regressions; no Stata, network, or external fixture generator. */
public final class ZipTransactionTest {
    private static int assertions;
    private static Path base;
    public static void main(String[] args) throws Exception {
        base = Files.createTempDirectory("suso-zip-transaction-test-");
        try {
            testWholeArchiveFailure();
            testPreservedDestinationAndManifest();
            testDateFolderMergeAndRetainedHistory();
            testPublishRollback();
            testMetadataRollback();
            testImmutableJournalSnapshots();
            testJournalPublicationFailure();
            testRejectedMoveKeepsOriginal();
            testRollbackFailureAndPendingLock();
            testExistingConflictsAndReservedState();
            testUnsafeNames();
            testSymlinks();
            testEncrypted();
            testZip64();
            testDirectoryData();
            testMetadataAndCommentSignatures();
            System.out.println("PASS ZipTransactionTest: " + assertions + " assertions");
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(base)) {
                paths.sorted(java.util.Comparator.reverseOrder()).forEach(p -> {
                    try { Files.delete(p); } catch (IOException e) { throw new RuntimeException(e); }
                });
            }
        }
    }

    private static void testWholeArchiveFailure() throws Exception {
        Path old = Files.createDirectory(base.resolve("old"));
        Files.writeString(old.resolve("first.txt"), "old first");
        Files.writeString(old.resolve("last.txt"), "old last");
        Files.writeString(old.resolve("unrelated.txt"), "retain me");
        byte[] archive = stored(List.of(new Item("first.txt", "replacement first"),
                new Item("last.txt", "replacement last").corrupt()), false);
        Path source = write("corrupt-last.zip", archive);
        Map<String, String> before = tree(old);
        long childrenBefore = children(base);
        Zip.Result failed = Zip.extract(source.toString(), old.toString(), "");
        check(failed.error != null && failed.error.contains("CRC"), "last entry corruption rejected");
        check(failed.files == 0 && failed.names.isEmpty() && failed.bytes == 0, "failure publishes zero counts");
        check(tree(old).equals(before), "every old destination file retained");
        check(children(base) == childrenBefore, "failed extraction leaves no sibling/stage");
        check(Arrays.equals(archive, Files.readAllBytes(source)), "source archive unchanged after failure");
        Path fresh = base.resolve("fresh-failure");
        Zip.Result newFailed = Zip.extract(source.toString(), fresh.toString(), "");
        check(newFailed.error != null && !Files.exists(fresh), "no partial final directory on late failure");
        check(children(base) == childrenBefore, "fresh failure removes private stage");
        byte[] truncated = Arrays.copyOf(archive, archive.length - 8);
        Path trunc = write("truncated.zip", truncated);
        check(Zip.extract(trunc.toString(), base.resolve("truncated-out").toString(), "").error != null,
                "truncated end record rejected");
    }

    @SuppressWarnings("unchecked")
    private static void testPreservedDestinationAndManifest() throws Exception {
        Path source = base.resolve("safe.zip");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(source))) {
            for (String name : List.of("nested/", "nested/data.csv", "zero.txt", "names-é.csv")) {
                out.putNextEntry(new ZipEntry(name));
                if (!name.endsWith("/") && !name.equals("zero.txt")) out.write((name + "\n").getBytes(StandardCharsets.UTF_8));
                out.closeEntry();
            }
        }
        byte[] sourceBefore = Files.readAllBytes(source);
        Path requested = Files.createDirectory(base.resolve("requested"));
        Files.writeString(requested.resolve("nested-original.txt"), "original");
        java.util.Set<java.nio.file.attribute.PosixFilePermission> originalPermissions = null;
        if (Files.getFileStore(requested).supportsFileAttributeView("posix")) {
            Files.setPosixFilePermissions(requested, PosixFilePermissions.fromString("rwxr-x---"));
            originalPermissions = Files.getPosixFilePermissions(requested);
        }
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "");
        check(result.error == null, "safe extraction succeeds: " + result.error);
        Path actual = Path.of(result.dir);
        check(actual.equals(requested), "existing destination uses exact requested folder");
        check("original".equals(Files.readString(requested.resolve("nested-original.txt"))), "unrelated existing file retained");
        check(!Files.exists(requested.resolve(".suso-extraction.lock")), "successful extraction releases folder lock");
        check(result.files == 3 && result.names.size() == 3, "count includes zero-length files, excludes manifest/directories");
        check(Path.of(result.manifest).getParent().equals(actual.resolve(".suso-manifests")), "per-run manifest path returned");
        java.util.UUID.fromString(Path.of(result.manifest).getFileName().toString().replace(".json", ""));
        check(Arrays.equals(Files.readAllBytes(Path.of(result.manifest)), Files.readAllBytes(actual.resolve(".suso-manifest.json"))), "latest manifest matches per-run manifest");
        Map<String, Object> manifest = (Map<String, Object>)Json.parse(Files.readString(Path.of(result.manifest)));
        check("suso-extraction-manifest".equals(manifest.get("format")), "manifest format");
        check(((Number)manifest.get("version")).intValue() == 2, "manifest version");
        check("archive-files".equals(manifest.get("scope")), "manifest scope excludes unrelated folder content");
        check("safe.zip".equals(manifest.get("archive")), "manifest stores archive basename only");
        java.time.Instant.parse((String)manifest.get("completed_utc"));
        long count = 0, bytes = 0;
        for (Object value : (List<Object>)manifest.get("files")) {
            Map<String, Object> item = (Map<String, Object>)value;
            Path file = actual.resolve((String)item.get("path"));
            byte[] content = Files.readAllBytes(file);
            CRC32 crc = new CRC32(); crc.update(content);
            check(hex(MessageDigest.getInstance("SHA-256").digest(content)).equals(item.get("sha256")), "manifest SHA-256 " + file);
            check(String.format(java.util.Locale.ROOT, "%08x", crc.getValue()).equals(item.get("crc32")), "manifest CRC " + file);
            check(content.length == ((Number)item.get("bytes")).longValue(), "manifest size " + file);
            count++; bytes += content.length;
        }
        check(count == 3 && count == ((Number)manifest.get("file_count")).longValue(), "manifest total files");
        check(bytes == result.bytes && bytes == ((Number)manifest.get("bytes")).longValue(), "manifest total bytes");
        check(Arrays.equals(sourceBefore, Files.readAllBytes(source)), "source archive unchanged after success");
        if (Files.getFileStore(actual).supportsFileAttributeView("posix")) {
            check(Files.getPosixFilePermissions(actual).equals(originalPermissions), "existing destination permissions remain unchanged");
            check(Files.getPosixFilePermissions(actual.resolve("nested/data.csv")).equals(PosixFilePermissions.fromString("rw-------")), "private output file");
        }
        Path empty = Files.createDirectory(base.resolve("empty-existing"));
        Zip.Result emptyResult = Zip.extract(source.toString(), empty.toString(), "");
        check(emptyResult.error == null && Path.of(emptyResult.dir).equals(empty) && Files.exists(empty.resolve("nested/data.csv")),
                "existing empty destination populated in place");
        Path fresh = base.resolve("fresh-good");
        Zip.Result freshResult = Zip.extract(source.toString(), fresh.toString(), "");
        check(freshResult.error == null && Path.of(freshResult.dir).equals(fresh), "new destination uses requested path");
        if (Files.getFileStore(fresh).supportsFileAttributeView("posix")) {
            check(Files.getPosixFilePermissions(fresh).equals(PosixFilePermissions.fromString("rwx------")), "fresh output root is private");
        }
    }

    @SuppressWarnings("unchecked")
    private static void testDateFolderMergeAndRetainedHistory() throws Exception {
        Path requested = Files.createDirectory(base.resolve("2026-09-04"));
        String qxName = "Questionnaire/Preview/English Global_informal2026.html";
        Files.createDirectories(requested.resolve(qxName).getParent());
        Files.writeString(requested.resolve(qxName), "previous questionnaire");
        Files.writeString(requested.resolve("Global_informal2026.dta"), "previous survey data");
        Files.writeString(requested.resolve("my-analysis.do"), "unrelated analysis");
        byte[] archive = stored(List.of(new Item(qxName, "current questionnaire"),
                new Item("Global_informal2026.dta", "current survey data"), new Item("interview__actions.tab", "current actions")), false);
        Path source = Files.write(requested.resolve("ises_2026-09-04.zip"), archive);
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "");
        check(result.error == null && Path.of(result.dir).equals(requested), "date folder used exactly: " + result.error);
        check("current questionnaire".equals(Files.readString(requested.resolve(qxName))), "questionnaire relative path points at fresh export");
        check("current survey data".equals(Files.readString(requested.resolve("Global_informal2026.dta"))), "survey relative path points at fresh export");
        check("unrelated analysis".equals(Files.readString(requested.resolve("my-analysis.do"))), "user analysis retained");
        check(Arrays.equals(archive, Files.readAllBytes(source)), "archive inside destination retained byte-for-byte");
        check(result.backupDir != null, "overwritten files return a backup folder");
        Path backup = Path.of(result.backupDir);
        check(backup.startsWith(requested.resolve(".suso-backups")), "backup remains inside requested date folder");
        check("previous questionnaire".equals(Files.readString(backup.resolve(qxName))), "old questionnaire retained at original relative path in backup");
        check("previous survey data".equals(Files.readString(backup.resolve("Global_informal2026.dta"))), "old survey retained at original relative path in backup");
        check(!Files.exists(backup.resolve("my-analysis.do")), "unrelated file is not moved to backup");
        check(!Files.exists(backup.resolve("ises_2026-09-04.zip")), "source archive is not moved to backup");
        Path oldManifest = Path.of(result.manifest);
        byte[] oldManifestBytes = Files.readAllBytes(oldManifest);
        Map<String, String> oldBackups = tree(backup);
        byte[] paradataArchive = stored(List.of(new Item("paradata.tab", "event\tinterview\nAnswerSet\t123\n")), false);
        Path paradataSource = Files.write(requested.resolve("suso_paradata_20260904.zip"), paradataArchive);
        Zip.Result paradata = Zip.extract(paradataSource.toString(), requested.toString(), "");
        check(paradata.error == null && Path.of(paradata.dir).equals(requested), "paradata also stays in same date folder: " + paradata.error);
        check(Files.readString(requested.resolve("paradata.tab")).startsWith("event\tinterview"), "paradata file is accessible relative to date folder");
        check("current survey data".equals(Files.readString(requested.resolve("Global_informal2026.dta"))), "subsequent paradata extraction keeps survey data");
        check("current questionnaire".equals(Files.readString(requested.resolve(qxName))), "subsequent paradata extraction keeps questionnaire");
        check(Arrays.equals(paradataArchive, Files.readAllBytes(paradataSource)), "paradata archive retained");
        check(Arrays.equals(oldManifestBytes, Files.readAllBytes(oldManifest)), "prior per-run manifest retained unchanged");
        check(!oldManifest.equals(Path.of(paradata.manifest)), "successive extracts have distinct immutable manifest paths");
        check(Arrays.equals(Files.readAllBytes(Path.of(paradata.manifest)), Files.readAllBytes(requested.resolve(".suso-manifest.json"))), "latest manifest follows latest successful extract");
        Map<String, Object> manifest = (Map<String, Object>)Json.parse(Files.readString(Path.of(paradata.manifest)));
        List<Object> files = (List<Object>)manifest.get("files");
        check(files.size() == 1 && "paradata.tab".equals(((Map<String, Object>)files.get(0)).get("path")), "paradata manifest inventories only its own archive files");
        check("archive-files".equals(manifest.get("scope")), "latest manifest clearly states archive-only scope");
        check(oldBackups.equals(tree(backup)), "earlier backup history retained unchanged");
        check(!Files.exists(requested.resolve(".suso-extraction.lock")), "date-folder sequence releases lock");
    }

    private static void testPublishRollback() throws Exception {
        Path requested = Files.createDirectory(base.resolve("publish-failure"));
        Files.writeString(requested.resolve("first.txt"), "old first");
        Files.writeString(requested.resolve("z-last.txt"), "old last");
        Files.writeString(requested.resolve("unrelated.txt"), "retain me");
        Files.writeString(requested.resolve(".suso-manifest.json"), "old latest manifest");
        Path source = write("publish-failure.zip", stored(List.of(new Item("first.txt", "new first"),
                new Item("new-directory/new.txt", "new file"), new Item("z-last.txt", "new last")), false));
        List<Path> published = new ArrayList<>();
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, path) -> {
            if (operation.equals("publish")) {
                if (path.equals(requested.resolve("z-last.txt"))) throw new IOException("injected later publish failure");
                published.add(path);
            }
        });
        check(result.error != null && result.error.contains("injected later publish failure"), "later publish error reported");
        check(published.contains(requested.resolve("first.txt")) && published.contains(requested.resolve("new-directory/new.txt")), "failure follows both replacement and new-file publication");
        check("old first".equals(Files.readString(requested.resolve("first.txt"))), "rollback restores already-overwritten file");
        check("old last".equals(Files.readString(requested.resolve("z-last.txt"))), "later target remains original");
        check(!Files.exists(requested.resolve("new-directory/new.txt")), "rollback removes newly published file");
        check(!Files.exists(requested.resolve("new-directory")), "rollback removes created empty parent directory");
        check("old latest manifest".equals(Files.readString(requested.resolve(".suso-manifest.json"))), "rollback retains original latest manifest");
        check("retain me".equals(Files.readString(requested.resolve("unrelated.txt"))), "rollback retains unrelated file");
        check(result.files == 0 && result.bytes == 0 && result.names.isEmpty(), "rolled-back extraction returns no published file counts");
        check(result.backupDir != null && Files.exists(Path.of(result.backupDir)), "rollback retains backups and returns their location");
        check("old first".equals(Files.readString(Path.of(result.backupDir).resolve("first.txt"))), "backup survives restoration");
        check(!Files.exists(requested.resolve(".suso-extraction.lock")), "successful rollback releases lock");
        Zip.Result retry = Zip.extract(source.toString(), requested.toString(), "");
        check(retry.error == null && "new first".equals(Files.readString(requested.resolve("first.txt"))), "retry allowed after fully completed rollback");
    }

    private static void testMetadataRollback() throws Exception {
        Path requested = Files.createDirectory(base.resolve("metadata-publish-failure"));
        Files.writeString(requested.resolve("first.txt"), "old first");
        Files.writeString(requested.resolve(".suso-manifest.json"), "old latest manifest");
        Path source = write("metadata-publish-failure.zip", stored(List.of(new Item("first.txt", "new first")), false));
        List<Path> manifestPublications = new ArrayList<>();
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, path) -> {
            if (operation.equals("publish")) {
                if (path.getParent().equals(requested.resolve(".suso-manifests"))) manifestPublications.add(path);
                if (path.equals(requested.resolve(".suso-manifest.json"))) throw new IOException("injected latest manifest failure");
            }
        });
        check(result.error != null && result.error.contains("injected latest manifest failure"), "metadata publication participates in transaction");
        check(manifestPublications.size() == 1, "per-run manifest publishes before latest manifest");
        check(!Files.exists(manifestPublications.get(0)), "failed transaction removes published per-run manifest");
        check("old first".equals(Files.readString(requested.resolve("first.txt"))), "metadata failure also rolls back data");
        check("old latest manifest".equals(Files.readString(requested.resolve(".suso-manifest.json"))), "metadata failure restores previous latest manifest");
        check(!Files.exists(requested.resolve(".suso-extraction.lock")), "metadata rollback releases lock");
        check(result.files == 0 && result.bytes == 0, "metadata failure reports zero published counts");
    }

    @SuppressWarnings("unchecked")
    private static void testImmutableJournalSnapshots() throws Exception {
        Path requested = Files.createDirectory(base.resolve("immutable-journal"));
        Files.writeString(requested.resolve("first.txt"), "old first");
        Path source = write("immutable-journal.zip", stored(List.of(new Item("first.txt", "new first"),
                new Item("nested/new.txt", "new file")), false));
        Map<Path, String> completeSnapshots = new LinkedHashMap<>();
        java.util.Set<Path> attemptedTargets = new java.util.HashSet<>();
        List<String> states = new ArrayList<>();
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, target) -> {
            if (!operation.equals("journal-publish")) return;
            // Model a provider/reader that refuses replacing a journal path. The
            // transaction must finish without ever invoking that failure mode.
            if (Files.exists(target, LinkOption.NOFOLLOW_LINKS) || !attemptedTargets.add(target)) {
                throw new java.nio.file.AccessDeniedException(target.toString(), null, "journal replacement denied");
            }
            boolean unchanged = true;
            for (Map.Entry<Path, String> previous : completeSnapshots.entrySet()) {
                unchanged &= previous.getValue().equals(Files.readString(previous.getKey()));
            }
            check(unchanged, "previous complete journal snapshots remain unchanged");
            try (java.util.stream.Stream<Path> paths = Files.list(target.getParent())) {
                for (Path path : paths.filter(p -> p.getFileName().toString().matches("journal-[0-9]{20}\\.json"))
                        .collect(java.util.stream.Collectors.toList())) {
                    completeSnapshots.put(path, Files.readString(path));
                }
            }
            Path next = target.resolveSibling(target.getFileName().toString().replace(".json", ".next"));
            Map<String, Object> value = (Map<String, Object>)Json.parse(Files.readString(next));
            check(((Number)value.get("version")).intValue() == 2, "journal snapshot format version is explicit");
            long sequence = ((Number)value.get("sequence")).longValue();
            check(target.getFileName().toString().equals(String.format(java.util.Locale.ROOT,
                    "journal-%020d.json", sequence)), "snapshot filename agrees with its sequence");
            states.add((String)value.get("state"));
        });
        check(result.error == null, "unique journal publication succeeds when replacement is denied: " + result.error);
        check(states.size() > 8 && states.containsAll(List.of("VALIDATING", "PREPARED", "COMMITTING", "COMMITTED")),
                "all transaction phases receive distinct snapshots");
        check(completeSnapshots.size() == attemptedTargets.size() - 1, "every prior snapshot remains until transaction cleanup");
        check("new first".equals(Files.readString(requested.resolve("first.txt"))), "journal fix preserves actual data publication");
        check(!Files.exists(requested.resolve(".suso-extraction.lock")), "successful snapshot transaction releases lock");
    }

    @SuppressWarnings("unchecked")
    private static void testJournalPublicationFailure() throws Exception {
        Path source = write("journal-failure.zip", stored(List.of(new Item("first.txt", "new first"),
                new Item("last.txt", "new last")), false));
        for (boolean persistent : List.of(false, true)) {
            Path requested = Files.createDirectory(base.resolve(persistent ? "persistent-journal-failure" : "single-journal-failure"));
            Files.writeString(requested.resolve("first.txt"), "old first");
            Files.writeString(requested.resolve("last.txt"), "old last");
            boolean[] failed = {false};
            Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, target) -> {
                if (!operation.equals("journal-publish")) return;
                Path next = target.resolveSibling(target.getFileName().toString().replace(".json", ".next"));
                Map<String, Object> value = (Map<String, Object>)Json.parse(Files.readString(next));
                List<Object> files = (List<Object>)value.get("files");
                boolean afterFirstPublish = "COMMITTING".equals(value.get("state")) && !files.isEmpty()
                        && "published".equals(((Map<String, Object>)files.get(0)).get("status"));
                if ((!failed[0] && afterFirstPublish) || (failed[0] && persistent)) {
                    failed[0] = true;
                    throw new java.nio.file.AccessDeniedException(target.toString(), null, "injected journal publication failure");
                }
            });
            check(failed[0] && result.error != null && result.error.contains("injected journal publication failure"),
                    "journal failure after actual data publication is reported");
            check("old first".equals(Files.readString(requested.resolve("first.txt"))), "journal failure restores overwritten data");
            check("old last".equals(Files.readString(requested.resolve("last.txt"))), "journal failure leaves unpublished data intact");
            check("old first".equals(Files.readString(Path.of(result.backupDir).resolve("first.txt"))), "journal failure retains original backup");
            if (persistent) {
                check(result.transactionDir != null && Files.isDirectory(Path.of(result.transactionDir)),
                        "persistent journal failure retains transaction for inspection");
                check(result.files == -1 && result.bytes == -1, "failed recovery journal does not claim a certain published count");
                Path transaction = Path.of(result.transactionDir);
                Map<String, Object> latest = latestJournal(transaction);
                check("COMMITTING".equals(latest.get("state")), "last complete pre-failure snapshot remains available");
                List<Object> files = (List<Object>)latest.get("files");
                check("publishing".equals(((Map<String, Object>)files.get(0)).get("status")),
                        "retained snapshot records operation that might have run");
                Files.writeString(transaction.resolve("journal-99999999999999999999.next"), "{partial");
                check(latest.equals(latestJournal(transaction)), "incomplete higher generation cannot supersede complete snapshot");
                check(Files.exists(requested.resolve(".suso-extraction.lock")), "persistent journal failure retains lock");
                Map<String, String> beforeRetry = tree(requested);
                check(Zip.extract(source.toString(), requested.toString(), "").error != null,
                        "pending failed journal transaction blocks retry");
                check(beforeRetry.equals(tree(requested)), "blocked retry does not alter recovery evidence");
            } else {
                check(result.files == 0 && result.bytes == 0, "completed journal rollback reports zero published bytes");
                check(!Files.exists(requested.resolve(".suso-extraction.lock")), "completed journal rollback releases lock");
                check(Zip.extract(source.toString(), requested.toString(), "").error == null,
                        "retry succeeds after completed journal rollback");
            }
        }
    }

    private static void testRejectedMoveKeepsOriginal() throws Exception {
        Path source = write("rejected-file-move.zip", stored(List.of(new Item("first.txt", "new first"),
                new Item("last.txt", "new last")), false));
        for (boolean existing : List.of(false, true)) {
            Path requested = Files.createDirectory(base.resolve(existing ? "locked-original" : "rejected-new-file"));
            Files.writeString(requested.resolve("first.txt"), "old first");
            if (existing) Files.writeString(requested.resolve("last.txt"), "old last");
            List<Path> restores = new ArrayList<>();
            Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, target) -> {
                if (operation.equals("file-move") && target.equals(requested.resolve("last.txt"))) {
                    throw new java.nio.file.AccessDeniedException(target.toString(), null, "injected unchanged target");
                }
                if (operation.equals("restore")) {
                    restores.add(target);
                    if (target.equals(requested.resolve("last.txt"))) throw new IOException("unchanged target must not be restored");
                }
            });
            check(result.error != null && result.error.contains("injected unchanged target"), "rejected atomic move is reported");
            check(result.error.contains("every published change was rolled back"), "unchanged target does not cause false rollback failure");
            check(restores.equals(List.of(requested.resolve("first.txt"))), "rollback only restores actually changed target");
            check("old first".equals(Files.readString(requested.resolve("first.txt"))), "earlier replaced file restored after rejected move");
            check(existing ? "old last".equals(Files.readString(requested.resolve("last.txt"))) : !Files.exists(requested.resolve("last.txt")),
                    "rejected move retains original target state");
            check(result.files == 0 && result.bytes == 0 && result.transactionDir == null,
                    "fully restored files have known zero counts and no pending transaction");
            check(!Files.exists(requested.resolve(".suso-extraction.lock")), "unchanged rejected target does not leave a false pending lock");
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> latestJournal(Path transaction) throws IOException {
        Path latest;
        try (java.util.stream.Stream<Path> paths = Files.list(transaction)) {
            latest = paths.filter(p -> p.getFileName().toString().matches("journal-[0-9]{20}\\.json"))
                    .max(java.util.Comparator.comparing(p -> p.getFileName().toString()))
                    .orElseThrow(() -> new IOException("no complete journal snapshot"));
        }
        if (!Files.isRegularFile(latest, LinkOption.NOFOLLOW_LINKS)) throw new IOException("unsafe journal snapshot");
        Map<String, Object> value = (Map<String, Object>)Json.parse(Files.readString(latest));
        long sequence = ((Number)value.get("sequence")).longValue();
        if (!latest.getFileName().toString().equals(String.format(java.util.Locale.ROOT, "journal-%020d.json", sequence))) {
            throw new IOException("journal filename and sequence disagree");
        }
        return value;
    }

    private static void testRollbackFailureAndPendingLock() throws Exception {
        Path requested = Files.createDirectory(base.resolve("restore-failure"));
        Files.writeString(requested.resolve("first.txt"), "old first");
        Files.writeString(requested.resolve("last.txt"), "old last");
        Path source = write("restore-failure.zip", stored(List.of(new Item("first.txt", "new first"), new Item("last.txt", "new last")), false));
        Zip.Result result = Zip.extract(source.toString(), requested.toString(), "", (operation, path) -> {
            if (operation.equals("publish") && path.equals(requested.resolve("last.txt"))) throw new IOException("injected publish failure");
            if (operation.equals("restore") && path.equals(requested.resolve("first.txt"))) throw new IOException("injected restore failure");
        });
        check(result.error != null && result.error.contains("injected restore failure"), "rollback error reported explicitly");
        check(result.transactionDir != null && Files.isDirectory(Path.of(result.transactionDir)), "incomplete rollback exposes retained transaction directory");
        Path transaction = Path.of(result.transactionDir);
        check(transaction.startsWith(requested.resolve(".suso-transactions")), "pending transaction remains inside requested folder");
        check(result.error.contains(result.transactionDir), "error identifies exact pending transaction path");
        Map<String, Object> journal = latestJournal(transaction);
        check("RECOVERY_REQUIRED".equals(journal.get("state")), "pending transaction retains latest complete recovery journal");
        check(Files.exists(requested.resolve(".suso-extraction.lock")), "incomplete rollback retains lock");
        check(result.backupDir != null && "old first".equals(Files.readString(Path.of(result.backupDir).resolve("first.txt"))), "failed restore retains original file in backup");
        check(result.files == -1 && result.bytes == -1, "partial transaction counts are explicitly unknown");
        Map<String, String> pending = tree(requested);
        Zip.Result retry = Zip.extract(source.toString(), requested.toString(), "");
        check(retry.error != null, "unresolved transaction blocks subsequent extraction");
        check(retry.files == -1 && retry.bytes == -1, "blocked retry does not claim known zero counts for pending partial state");
        check(retry.transactionDir != null && Files.exists(Path.of(retry.transactionDir)), "blocked retry exposes existing pending state path");
        check(retry.error.contains(retry.transactionDir), "blocked retry error identifies pending state location");
        check(pending.equals(tree(requested)), "blocked retry leaves pending journal, backups and files unchanged");
    }

    private static void testExistingConflictsAndReservedState() throws Exception {
        Path directoryConflict = Files.createDirectory(base.resolve("existing-directory-conflict"));
        Files.createDirectory(directoryConflict.resolve("data"));
        Files.writeString(directoryConflict.resolve("data/original"), "retain");
        checkPreservedRejection(write("existing-directory-conflict.zip", stored(List.of(new Item("data", "replacement")), false)), directoryConflict,
                "archive file cannot overwrite existing directory");
        Path fileConflict = Files.createDirectory(base.resolve("existing-file-conflict"));
        Files.writeString(fileConflict.resolve("data"), "retain");
        checkPreservedRejection(write("existing-file-conflict.zip", stored(List.of(new Item("data/new.txt", "replacement")), false)), fileConflict,
                "archive directory cannot overwrite existing file");
        Path sourceConflict = Files.createDirectory(base.resolve("source-overwrite-conflict"));
        Path source = sourceConflict.resolve("source.zip");
        Files.write(source, stored(List.of(new Item("first.txt", "new"), new Item("source.zip", "overwrite original archive")), false));
        checkPreservedRejection(source, sourceConflict, "archive cannot overwrite its own source ZIP");
        Path lockConflict = Files.createDirectory(base.resolve("preexisting-lock"));
        Files.createDirectories(lockConflict.resolve(".suso-transactions/pending"));
        Files.writeString(lockConflict.resolve(".suso-transactions/pending/journal.json"), "{}");
        Files.createDirectory(lockConflict.resolve(".suso-extraction.lock"));
        Files.writeString(lockConflict.resolve(".suso-extraction.lock/owner.json"), "{\"transaction\":\"pending\"}");
        Zip.Result locked = checkPreservedRejection(write("preexisting-lock.zip", stored(List.of(new Item("data.txt", "new")), false)), lockConflict,
                "pre-existing pending extraction blocks publication", -1);
        check(locked.transactionDir != null && Files.exists(Path.of(locked.transactionDir)), "pre-existing lock returns pending state location");
        check(locked.error.contains(locked.transactionDir), "pre-existing lock error identifies pending state location");
        Path orphaned = Files.createDirectory(base.resolve("preexisting-orphaned-transaction"));
        Files.createDirectories(orphaned.resolve(".suso-transactions/pending"));
        Files.writeString(orphaned.resolve(".suso-transactions/pending/journal.json"), "{}");
        Zip.Result orphan = checkPreservedRejection(write("preexisting-orphaned-transaction.zip", stored(List.of(new Item("data.txt", "new")), false)), orphaned,
                "pre-existing transaction without lock still blocks publication", -1);
        check(orphan.transactionDir != null && Files.exists(Path.of(orphan.transactionDir)), "orphaned transaction returns pending state location");
        check(orphan.error.contains(orphan.transactionDir), "orphaned transaction error identifies pending state location");
    }

    private static Zip.Result checkPreservedRejection(Path source, Path destination, String message) throws Exception {
        return checkPreservedRejection(source, destination, message, 0);
    }

    private static Zip.Result checkPreservedRejection(Path source, Path destination, String message, long expectedCount) throws Exception {
        Map<String, String> before = tree(destination);
        byte[] archive = Files.readAllBytes(source);
        Zip.Result result = Zip.extract(source.toString(), destination.toString(), "");
        check(result.error != null && result.files == expectedCount && result.bytes == expectedCount, message);
        check(before.equals(tree(destination)), message + " leaves old tree unchanged");
        check(Arrays.equals(archive, Files.readAllBytes(source)), message + " leaves source unchanged");
        return result;
    }

    private static void testUnsafeNames() throws Exception {
        List<List<Item>> cases = new ArrayList<>();
        for (String name : List.of("../escape.txt", "/absolute", "C:/drive", "a/../escape", "a//file", "a/./file",
                "trailing.", "trailing ", "bad:stream", "CON", "NUL.csv", "COM1.txt", "LPT².csv", "bad\u0000name",
                "tab\tname", ".suso-manifest.json", ".SUSO-MANIFEST.JSON/child", "bad?name", "bad*name",
                "NUL .txt", "COM1 .csv", "CONIN$", "CONOUT$", ".suso-backups/x", ".suso-manifests/x",
                ".suso-transactions/x", ".suso-extraction.lock", ".SUSO-BACKUPS/x", ".SUSO-MANIFESTS/x",
                ".SUSO-TRANSACTIONS/x", ".SUSO-EXTRACTION.LOCK/child")) {
            cases.add(List.of(new Item(name, "x")));
        }
        cases.add(List.of(new Item("same", "1"), new Item("same", "2")));
        cases.add(List.of(new Item("Same", "1"), new Item("same", "2")));
        cases.add(List.of(new Item("a/b", "1"), new Item("a\\b", "2")));
        cases.add(List.of(new Item("A/one", "1"), new Item("a/two", "2")));
        cases.add(List.of(new Item("é/one", "1"), new Item("e\u0301/two", "2")));
        cases.add(List.of(new Item("file", "1"), new Item("file/nested", "2")));
        cases.add(List.of(new Item("file/nested", "1"), new Item("file", "2")));
        cases.add(List.of(new Item("directory/", ""), new Item("directory/", "")));
        int i = 0;
        for (List<Item> items : cases) {
            Path source = write("unsafe-" + i + ".zip", stored(items, false));
            Path destination = base.resolve("unsafe-out-" + i++);
            long count = children(base);
            Zip.Result result = Zip.extract(source.toString(), destination.toString(), "");
            check(result.error != null && result.files == 0, "unsafe/aliased path rejected: " + items.get(0).name);
            check(!Files.exists(destination) && children(base) == count, "unsafe path left no partial output");
        }
    }

    private static void testSymlinks() throws Exception {
        Path source = write("symlink-entry.zip", stored(List.of(new Item("link", "outside").symlink()), false));
        check(Zip.extract(source.toString(), base.resolve("symbolic-entry-out").toString(), "").error != null,
                "archive symlink rejected");
        Path outside = Files.createDirectory(base.resolve("outside"));
        Files.writeString(outside.resolve("sentinel.txt"), "outside original");
        Path alias = base.resolve("alias");
        try { Files.createSymbolicLink(alias, outside); }
        catch (UnsupportedOperationException | IOException | SecurityException unavailable) { return; }
        Path safe = write("link-safe.zip", stored(List.of(new Item("sentinel.txt", "new content")), false));
        check(Zip.extract(safe.toString(), alias.toString(), "").error != null, "symlink destination rejected");
        check(Zip.extract(safe.toString(), alias.resolve("new").toString(), "").error != null, "symlink ancestor rejected");
        check("outside original".equals(Files.readString(outside.resolve("sentinel.txt"))), "outside target unchanged");
        Path old = Files.createDirectory(base.resolve("old-with-symlink"));
        Files.createSymbolicLink(old.resolve("sentinel.txt"), outside.resolve("sentinel.txt"));
        Zip.Result alternate = Zip.extract(safe.toString(), old.toString(), "");
        check(alternate.error != null && alternate.files == 0, "existing overwritten symlink rejected");
        check(Files.isSymbolicLink(old.resolve("sentinel.txt")), "old symlink retained");
        check("outside original".equals(Files.readString(outside.resolve("sentinel.txt"))), "rejected extraction does not follow old link");
    }

    private static void testEncrypted() throws Exception {
        String[] fixtures = {
            "UEsDBAoACQAAAIZjJV0i7QlDHgAAABIAAAAJABwAcGxhaW4udHh0VVQJAANLjJtqS4ybanV4CwABBAAAAAAEAAAAALoFY8yrTaH1vw96Tz4xwLDXytfgm1A091M67nrDFVBLBwgi7QlDHgAAABIAAABQSwECHgMKAAkAAACGYyVdIu0JQx4AAAASAAAACQAYAAAAAAABAAAApIEAAAAAcGxhaW4udHh0VVQFAANLjJtqdXgLAAEEAAAAAAQAAAAAUEsFBgAAAAABAAEATwAAAHEAAAAAAA==",
            "UEsDBBQACQAIAI5jJV0qDwK/bAAAAPBVAAAMABwAcmVwZWF0ZWQudHh0VVQJAANbjJtqW4ybanV4CwABBAAAAAAEAAAAAAh0fJ+PRK0PsSxBjawM1DY/bfa2Rk3iWNLth2ENzXha3ifhyjhTgxTXLbq09xSBaasj0lOcmXO6uJnpPH2rv52ZUzVPb4P/aA6Rl9rjbQhbECiq9f2fOMmoZxXWG/PLeAtszwv9Ws2y4CnLlFBLBwgqDwK/bAAAAPBVAABQSwECHgMUAAkACACOYyVdKg8Cv2wAAADwVQAADAAYAAAAAAABAAAApIEAAAAAcmVwZWF0ZWQudHh0VVQFAANbjJtqdXgLAAEEAAAAAAQAAAAAUEsFBgAAAAABAAEAUgAAAMIAAAAAAA=="
        };
        for (int i = 0; i < fixtures.length; i++) {
            Path archive = write("encrypted-" + i + ".zip", Base64.getDecoder().decode(fixtures[i]));
            Path destination = base.resolve("encrypted-out-" + i);
            Zip.Result good = Zip.extract(archive.toString(), destination.toString(), "secret");
            check(good.error == null && good.files == 1, "Info-ZIP encrypted fixture accepted: " + good.error);
            String expected = i == 0 ? "encrypted-content\n" : "survey-response\t12345\n".repeat(1000);
            String file = i == 0 ? "plain.txt" : "repeated.txt";
            check(expected.equals(Files.readString(Path.of(good.dir).resolve(file))), "encrypted plaintext exact");
            Map<String, String> before = tree(destination);
            long childrenBefore = children(base);
            for (String password : List.of("wrong", "")) {
                Zip.Result bad = Zip.extract(archive.toString(), destination.toString(), password);
                check(bad.error != null && bad.badPassword && bad.files == 0, "wrong/missing password rejected");
                check(before.equals(tree(destination)) && children(base) == childrenBefore, "password failure preserves old output and no stage");
            }
        }
    }

    private static void testZip64() throws Exception {
        Path source = write("zip64.zip", stored(List.of(new Item("zip64.txt", "small ZIP64 fixture")), true));
        Path destination = base.resolve("zip64-out");
        Zip.Result result = Zip.extract(source.toString(), destination.toString(), "");
        check(result.error == null && result.files == 1, "ZIP64 count/offset/entry metadata preserved: " + result.error);
        check("small ZIP64 fixture".equals(Files.readString(destination.resolve("zip64.txt"))), "ZIP64 content");
    }

    private static void testDirectoryData() throws Exception {
        Path source = write("directory-data.zip", stored(List.of(new Item("hidden/", "lost data")), false));
        check(Zip.extract(source.toString(), base.resolve("directory-data-out").toString(), "").error != null,
                "data hidden in directory entry must not be silently dropped");
        Path corrupt = write("directory-crc.zip", stored(List.of(new Item("empty/", "").badCrc()), false));
        check(Zip.extract(corrupt.toString(), base.resolve("directory-crc-out").toString(), "").error != null,
                "directory CRC also validated");
    }

    private static void testMetadataAndCommentSignatures() throws Exception {
        byte[] valid = stored(List.of(new Item("metadata.txt", "keep every byte")), false);
        int central = signature(valid, 0x02014b50);
        int end = valid.length - 22;
        for (int field : new int[]{14, 18, 22, central + 34}) {
            byte[] corrupt = valid.clone(); corrupt[field] ^= 1;
            Path source = write("metadata-" + field + ".zip", corrupt);
            Path destination = base.resolve("metadata-out-" + field);
            Zip.Result result = Zip.extract(source.toString(), destination.toString(), "");
            check(result.error != null && result.files == 0 && !Files.exists(destination), "contradictory local/disk metadata rejected " + field);
        }
        byte[] comment = Arrays.copyOf(valid, valid.length + 22);
        comment[end + 20] = 22;
        comment[valid.length] = 'P'; comment[valid.length + 1] = 'K'; comment[valid.length + 2] = 5; comment[valid.length + 3] = 6;
        Path source = write("eocd-comment.zip", comment);
        Zip.Result commented = Zip.extract(source.toString(), base.resolve("eocd-comment-out").toString(), "");
        check(commented.error == null && commented.files == 1, "empty EOCD inside comment cannot hide actual files");
        check("keep every byte".equals(Files.readString(Path.of(commented.dir).resolve("metadata.txt"))), "comment signature preserves content");

        ByteArrayOutputStream raw = new ByteArrayOutputStream();
        try (ZipOutputStream zipped = new ZipOutputStream(raw)) {
            zipped.putNextEntry(new ZipEntry("descriptor.txt")); zipped.write("descriptor content".getBytes(StandardCharsets.UTF_8)); zipped.closeEntry();
        }
        byte[] descriptorZip = raw.toByteArray();
        int descriptor = signature(descriptorZip, 0x08074b50);
        for (int field : new int[]{descriptor + 4, descriptor + 8, descriptor + 12}) {
            byte[] corrupt = descriptorZip.clone(); corrupt[field] ^= 1;
            Path bad = write("descriptor-" + field + ".zip", corrupt);
            Zip.Result result = Zip.extract(bad.toString(), base.resolve("descriptor-out-" + field).toString(), "");
            check(result.error != null && result.files == 0, "descriptor CRC/size mismatch rejected " + field);
        }
        byte[] wide = stored(List.of(new Item("wide", "ZIP64")), true);
        int locator = signature(wide, 0x07064b50), wideEnd = signature(wide, 0x06064b50);
        for (int field : new int[]{locator + 4, locator + 16, wideEnd + 4}) {
            byte[] corrupt = wide.clone(); corrupt[field] ^= 1;
            Path bad = write("zip64-metadata-" + field + ".zip", corrupt);
            check(Zip.extract(bad.toString(), base.resolve("zip64-metadata-out-" + field).toString(), "").error != null,
                    "ZIP64 locator/record mismatch rejected " + field);
        }
    }

    private static int signature(byte[] bytes, long signature) {
        for (int i = 0; i + 4 <= bytes.length; i++) {
            long value = (bytes[i] & 255L) | (bytes[i + 1] & 255L) << 8 | (bytes[i + 2] & 255L) << 16 | (bytes[i + 3] & 255L) << 24;
            if (value == signature) return i;
        }
        throw new AssertionError("fixture signature missing");
    }

    private static Path write(String name, byte[] value) throws IOException { return Files.write(base.resolve(name), value); }
    private static long children(Path directory) throws IOException {
        try (java.util.stream.Stream<Path> paths = Files.list(directory)) { return paths.count(); }
    }
    private static Map<String, String> tree(Path root) throws Exception {
        Map<String, String> files = new LinkedHashMap<>();
        try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
            for (Path file : (Iterable<Path>)paths.sorted()::iterator) {
                String name = root.relativize(file).toString();
                if (Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) files.put(name, hex(MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file))));
                else if (Files.isSymbolicLink(file)) files.put(name, "LINK:" + Files.readSymbolicLink(file));
                else files.put(name, "DIR");
            }
        }
        return files;
    }
    private static void check(boolean value, String message) {
        assertions++;
        if (!value) throw new AssertionError(message);
    }
    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte b : bytes) result.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        return result.toString();
    }
    private static final class Item {
        final String name; final byte[] data;
        boolean corrupt, wrongCrc, symlink;
        Item(String name, String value) { this.name = name; this.data = value.getBytes(StandardCharsets.UTF_8); }
        Item corrupt() { corrupt = true; return this; }
        Item badCrc() { wrongCrc = true; return this; }
        Item symlink() { symlink = true; return this; }
    }
    // A minimal stored ZIP fixture writer permits duplicate paths that ZipOutputStream rightly forbids.
    private static byte[] stored(List<Item> items, boolean zip64) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(), central = new ByteArrayOutputStream();
        for (Item item : items) {
            byte[] name = item.name.getBytes(StandardCharsets.UTF_8);
            CRC32 crc = new CRC32(); crc.update(item.data);
            long expectedCrc = item.wrongCrc ? crc.getValue() ^ 1 : crc.getValue();
            int offset = out.size();
            le(out, 0x04034b50, 4); le(out, 45, 2); le(out, 0x800, 2); le(out, 0, 2); le(out, 0, 4);
            le(out, expectedCrc, 4); le(out, zip64 ? 0xffffffffL : item.data.length, 4); le(out, zip64 ? 0xffffffffL : item.data.length, 4);
            le(out, name.length, 2); le(out, zip64 ? 20 : 0, 2); out.write(name);
            if (zip64) { le(out, 1, 2); le(out, 16, 2); le(out, item.data.length, 8); le(out, item.data.length, 8); }
            byte[] payload = item.data.clone(); if (item.corrupt && payload.length > 0) payload[0] ^= 1; out.write(payload);
            le(central, 0x02014b50, 4); le(central, 0x032d, 2); le(central, 45, 2); le(central, 0x800, 2); le(central, 0, 2); le(central, 0, 4);
            le(central, expectedCrc, 4); le(central, zip64 ? 0xffffffffL : item.data.length, 4); le(central, zip64 ? 0xffffffffL : item.data.length, 4);
            le(central, name.length, 2); le(central, zip64 ? 28 : 0, 2); le(central, 0, 2); le(central, 0, 2); le(central, 0, 2);
            le(central, item.symlink ? 0120777L << 16 : 0, 4); le(central, zip64 ? 0xffffffffL : offset, 4); central.write(name);
            if (zip64) { le(central, 1, 2); le(central, 24, 2); le(central, item.data.length, 8); le(central, item.data.length, 8); le(central, offset, 8); }
        }
        int centralOffset = out.size(); out.write(central.toByteArray());
        if (zip64) {
            int zip64Offset = out.size();
            le(out, 0x06064b50, 4); le(out, 44, 8); le(out, 45, 2); le(out, 45, 2); le(out, 0, 4); le(out, 0, 4);
            le(out, items.size(), 8); le(out, items.size(), 8); le(out, central.size(), 8); le(out, centralOffset, 8);
            le(out, 0x07064b50, 4); le(out, 0, 4); le(out, zip64Offset, 8); le(out, 1, 4);
        }
        le(out, 0x06054b50, 4); le(out, 0, 2); le(out, 0, 2); le(out, zip64 ? 0xffff : items.size(), 2); le(out, zip64 ? 0xffff : items.size(), 2);
        le(out, zip64 ? 0xffffffffL : central.size(), 4); le(out, zip64 ? 0xffffffffL : centralOffset, 4); le(out, 0, 2);
        return out.toByteArray();
    }
    private static void le(ByteArrayOutputStream out, long value, int bytes) {
        for (int i = 0; i < bytes; i++) { out.write((int)value & 255); value >>>= 8; }
    }
}
