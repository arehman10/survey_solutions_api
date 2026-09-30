package org.worldbank.suso;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.channels.Channels;
import java.nio.channels.FileChannel;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Publishes a verified archive inside its requested folder with retained prior files.
 * The persistent lock directory is acquired with CREATE_NEW semantics. It is never
 * reclaimed automatically: interruption or unresolved rollback requires inspection.
 * Individual file replacement is atomic, but a whole folder is not one atomic snapshot.
 */
final class ZipPublisher {
    static final String LOCK = ".suso-extraction.lock";
    static final String TRANSACTIONS = ".suso-transactions";
    static final String BACKUPS = ".suso-backups";
    static final String MANIFESTS = ".suso-manifests";
    static final String LATEST = ".suso-manifest.json";

    @FunctionalInterface
    interface FailureInjector {
        void check(String operation, Path path) throws IOException;
    }

    private final Path root;
    private final Path archive;
    private final String id = UUID.randomUUID().toString();
    private final FailureInjector injector;
    private final Zip.Result result;
    private final List<Operation> operations = new ArrayList<>();
    private final List<Path> madeDirectories = new ArrayList<>();
    private boolean rootCreated;
    private boolean lockOwned;
    private boolean transactionsCreated;
    private boolean backupsCreated;
    private boolean retainTransaction;
    private boolean published;
    private boolean finished;
    private Path transaction;
    private Path backup;
    private long journalSequence;
    private String state = "VALIDATING";
    Path stage;

    ZipPublisher(Path root, Path archive, FailureInjector injector, Zip.Result result) {
        this.root = root;
        this.archive = archive.toAbsolutePath().normalize();
        this.injector = injector;
        this.result = result;
    }

    void begin() throws IOException {
        if (root.getFileName() == null) throw new IOException("destination cannot be a filesystem root");
        inspectPath(root.getRoot(), root, true);
        rootCreated = !Files.exists(root, LinkOption.NOFOLLOW_LINKS);
        Zip.createSafeDirectories(root.getRoot(), root);
        for (String internal : List.of(BACKUPS, MANIFESTS, TRANSACTIONS)) {
            inspectPath(root, root.resolve(internal), true);
        }
        Path lock = root.resolve(LOCK);
        if (Files.exists(lock, LinkOption.NOFOLLOW_LINKS)) throw pending(lock);
        Path transactions = root.resolve(TRANSACTIONS);
        if (Files.isDirectory(transactions) && !isEmpty(transactions)) throw pending(transactions);
        // The atomic directory creation is the cross-process lock. Unlike removing
        // a FileLock inode, this cannot admit a waiter holding a stale file handle.
        try { Zip.createPrivateDirectory(lock); }
        catch (java.nio.file.FileAlreadyExistsException busy) { throw pending(lock); }
        lockOwned = true;
        writeJson(lock.resolve("owner.json"), Map.of("transaction_id", id,
                "started_utc", java.time.Instant.now().toString(), "archive", archive.getFileName().toString()));
        transactionsCreated = !Files.exists(transactions, LinkOption.NOFOLLOW_LINKS);
        Zip.createSafeDirectories(root, transactions);
        transaction = transactions.resolve(id);
        Zip.createPrivateDirectory(transaction);
        stage = transaction.resolve("stage");
        Zip.createPrivateDirectory(stage);
        journal();
    }

    private IOException pending(Path path) {
        result.transactionDir = path.toString();
        return new IOException("another extraction is active or unfinished; recover it before retrying. "
                + "Do not remove its lock until recovery is complete: " + path);
    }

    void publish(List<String> names, List<String> archiveDirectories, Path manifest) throws IOException {
        // No existing data is touched before all archive bytes and all paths pass.
        for (String name : names) add(stage.resolve(name), name);
        for (String directory : archiveDirectories) inspectPath(root, root.resolve(directory), true);
        Path perRunSource = transaction.resolve("manifest-run.json");
        copyVerified(manifest, perRunSource);
        add(perRunSource, MANIFESTS + "/" + id + ".json");
        add(manifest, LATEST);
        for (Operation operation : operations) {
            if (operation.existed) {
                if (backup == null) {
                    Path backups = root.resolve(BACKUPS);
                    backupsCreated = !Files.exists(backups, LinkOption.NOFOLLOW_LINKS);
                    Zip.createSafeDirectories(root, backups);
                    backup = backups.resolve(id);
                    Zip.createPrivateDirectory(backup);
                    result.backupDir = backup.toString();
                }
                Path prior = backup.resolve(operation.relative);
                Zip.createSafeDirectories(backup, prior.getParent());
                operation.originalHash = copyVerified(operation.target, prior);
                operation.backup = prior;
            }
        }
        state = "PREPARED";
        journal();
        try {
            state = "COMMITTING";
            journal();
            for (String directory : archiveDirectories) makePublishedDirectories(root.resolve(directory));
            for (Operation operation : operations) {
                makePublishedDirectories(operation.target.getParent());
                inspectPath(root, operation.target, false);
                // Refuse changes observed since the backup/preflight; SuSo itself
                // cannot race another extraction because this folder is locked.
                boolean exists = Files.exists(operation.target, LinkOption.NOFOLLOW_LINKS);
                if (exists != operation.existed || (exists && !operation.originalHash.equals(hash(operation.target)))) {
                    throw new IOException("destination changed during extraction: " + operation.target);
                }
                check("publish", operation.target);
                operation.status = "publishing";
                journal();
                operation.attempted = true;
                try { atomicMove(operation.source, operation.target); }
                catch (java.nio.file.AtomicMoveNotSupportedException unsupported) {
                    operation.attempted = false;
                    throw unsupported;
                }
                operation.status = "published";
                journal();
            }
            state = "COMMITTED";
            journal();
            published = true;
            result.manifest = root.resolve(MANIFESTS).resolve(id + ".json").toString();
            if (backup != null) result.notice = "Existing files backed up under " + backup;
        } catch (Throwable failure) {
            IOException restoreFailure = rollback();
            if (restoreFailure != null) {
                retainTransaction = true;
                result.transactionDir = transaction.toString();
                throw new IOException("publication failed; rollback is incomplete. Recover the transaction at "
                        + transaction + "; prior files are retained at " + backup
                        + ". Original failure: " + describe(failure)
                        + ". Recovery failure: " + describe(restoreFailure), failure);
            }
            throw new IOException("publication failed; every published change was rolled back"
                    + (backup == null ? "" : "; prior files retained at " + backup)
                    + ": " + describe(failure), failure);
        }
    }

    private void add(Path source, String relative) throws IOException {
        Path target = root.resolve(relative);
        inspectPath(root, target, false);
        if (target.equals(archive) || (Files.exists(target, LinkOption.NOFOLLOW_LINKS)
                && Files.isSameFile(target, archive))) {
            throw new IOException("ZIP entry would overwrite its source archive: " + target);
        }
        Operation operation = new Operation(source, target, relative,
                Files.exists(target, LinkOption.NOFOLLOW_LINKS));
        operations.add(operation);
    }

    private void makePublishedDirectories(Path directory) throws IOException {
        Path current = root;
        for (Path part : root.relativize(directory)) {
            current = current.resolve(part);
            if (Files.exists(current, LinkOption.NOFOLLOW_LINKS)) {
                inspectPath(root, current, true);
            } else {
                madeDirectories.add(current);
                // Persist the planned creation before doing it, for manual recovery.
                journal();
                try { Zip.createPrivateDirectory(current); }
                catch (IOException failure) {
                    // Never roll back a directory we did not actually create.
                    madeDirectories.remove(madeDirectories.size() - 1);
                    throw failure;
                }
            }
        }
    }

    private IOException rollback() {
        IOException errors = null;
        state = "ROLLING_BACK";
        try { journal(); } catch (IOException failure) { errors = failure; }
        List<Operation> reverse = new ArrayList<>(operations);
        Collections.reverse(reverse);
        for (Operation operation : reverse) {
            if (!operation.attempted) continue;
            try {
                inspectPath(root, operation.target, false);
                boolean exists = Files.exists(operation.target, LinkOption.NOFOLLOW_LINKS);
                // A rejected rename may not have changed anything. In particular,
                // avoid renaming over a locked original a second time in rollback.
                if (operation.existed && exists && operation.originalHash.equals(hash(operation.target))) {
                    operation.status = "rolled_back";
                    continue;
                }
                if (!operation.existed && !exists) {
                    operation.status = "rolled_back";
                    continue;
                }
                check("restore", operation.target);
                if (operation.existed) {
                    Path restore = transaction.resolve("restore-" + UUID.randomUUID());
                    String restoredHash = copyVerified(operation.backup, restore);
                    if (!restoredHash.equals(operation.originalHash)) {
                        throw new IOException("backup no longer matches its recorded SHA-256: " + operation.backup);
                    }
                    atomicMove(restore, operation.target);
                } else {
                    Files.deleteIfExists(operation.target);
                }
                operation.status = "rolled_back";
            } catch (IOException failure) {
                operation.status = "restore_failed";
                errors = combine(errors, failure);
            }
        }
        List<Path> reverseDirectories = new ArrayList<>(madeDirectories);
        Collections.reverse(reverseDirectories);
        for (Path directory : reverseDirectories) {
            try { Files.deleteIfExists(directory); }
            catch (IOException failure) { errors = combine(errors, failure); }
        }
        state = errors == null ? "ROLLED_BACK" : "RECOVERY_REQUIRED";
        try { journal(); } catch (IOException failure) { errors = combine(errors, failure); }
        return errors;
    }

    private static IOException combine(IOException previous, IOException next) {
        if (previous == null) return next;
        previous.addSuppressed(next);
        return previous;
    }

    private static String describe(Throwable failure) {
        String message = failure.getMessage();
        return failure.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }

    void finish() {
        if (finished) return;
        finished = true;
        if (retainTransaction) return;
        try {
            if (transaction != null) Zip.deleteTree(transaction);
            if (transactionsCreated) Files.deleteIfExists(root.resolve(TRANSACTIONS));
            if (backup != null && isEmpty(backup)) {
                Files.delete(backup);
                result.backupDir = null;
                if (backupsCreated) Files.deleteIfExists(root.resolve(BACKUPS));
            }
            if (lockOwned) Zip.deleteTree(root.resolve(LOCK));
            if (rootCreated && !published && isEmpty(root)) Files.delete(root);
        } catch (IOException cleanup) {
            retainTransaction = true;
            result.transactionDir = transaction == null ? root.resolve(LOCK).toString() : transaction.toString();
            String message = "extraction cleanup requires inspection at " + result.transactionDir
                    + ": " + cleanup.getMessage();
            result.error = result.error == null ? message : result.error + "; " + message;
        }
    }

    private void check(String operation, Path path) throws IOException {
        if (injector != null) injector.check(operation, path);
    }

    private void journal() throws IOException {
        Map<String, Object> value = new LinkedHashMap<>();
        value.put("format", "suso-extraction-transaction");
        value.put("version", 2);
        value.put("sequence", ++journalSequence);
        value.put("transaction_id", id);
        value.put("state", state);
        value.put("archive", archive.getFileName().toString());
        value.put("backup_dir", backup == null ? null : root.relativize(backup).toString().replace('\\', '/'));
        List<Map<String, Object>> steps = new ArrayList<>();
        for (Operation operation : operations) {
            Map<String, Object> step = new LinkedHashMap<>();
            step.put("path", operation.relative);
            step.put("existed", operation.existed);
            step.put("status", operation.status);
            step.put("prior_sha256", operation.originalHash);
            steps.add(step);
        }
        value.put("files", steps);
        List<String> directories = new ArrayList<>();
        for (Path path : madeDirectories) directories.add(root.relativize(path).toString().replace('\\', '/'));
        value.put("created_directories", directories);
        // Never replace an existing journal file. Repeated replacement can be
        // denied on Windows/network drives while another process scans the old
        // snapshot. Each forced, closed snapshot instead receives a new name.
        // For manual recovery, the greatest numbered .json is the latest complete
        // snapshot; a .next file is uncommitted and must never supersede it.
        String name = String.format(java.util.Locale.ROOT, "journal-%020d", journalSequence);
        Path next = transaction.resolve(name + ".next");
        Path complete = transaction.resolve(name + ".json");
        writeJson(next, value);
        check("journal-publish", complete);
        if (Files.exists(complete, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("journal snapshot already exists: " + complete);
        }
        // The transaction directory is private and protected by the folder lock.
        // No mutable 'latest' pointer or non-atomic replacement fallback is used.
        AtomicFiles.moveNew(next, complete);
    }

    private static void writeJson(Path file, Map<String, ?> value) throws IOException {
        Zip.createPrivateFile(file);
        try (FileChannel channel = FileChannel.open(file, StandardOpenOption.WRITE);
             OutputStream output = Channels.newOutputStream(channel)) {
            output.write((Json.write(value) + "\n").getBytes(java.nio.charset.StandardCharsets.UTF_8));
            output.flush();
            channel.force(true);
        }
    }

    private void atomicMove(Path from, Path to) throws IOException {
        // No non-atomic copy fallback: unsupported filesystems fail and roll back.
        check("file-move", to);
        AtomicFiles.move(from, to);
    }

    private static void inspectPath(Path root, Path target, boolean directory) throws IOException {
        if (!target.startsWith(root)) throw new IOException("destination path escapes requested folder: " + target);
        Path current = root;
        if (Files.isSymbolicLink(current)) throw new IOException("symbolic link in destination: " + current);
        for (Path part : root.relativize(target)) {
            current = current.resolve(part);
            if (!Files.exists(current, LinkOption.NOFOLLOW_LINKS)) continue;
            BasicFileAttributes attributes = Files.readAttributes(current, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            boolean expectsDirectory = !current.equals(target) || directory;
            if (attributes.isSymbolicLink() || (expectsDirectory ? !attributes.isDirectory() : !attributes.isRegularFile())) {
                throw new IOException("unsafe destination type or file/directory conflict: " + current);
            }
        }
    }

    private static String copyVerified(Path source, Path target) throws IOException {
        Zip.createPrivateFile(target);
        MessageDigest digest = sha256();
        try (InputStream input = Files.newInputStream(source);
             FileChannel channel = FileChannel.open(target, StandardOpenOption.WRITE);
             OutputStream output = Channels.newOutputStream(channel)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                output.write(buffer, 0, count);
                digest.update(buffer, 0, count);
            }
            output.flush();
            channel.force(true);
        }
        String expected = hex(digest.digest());
        if (!expected.equals(hash(target))) throw new IOException("backup/staging verification failed: " + target);
        return expected;
    }

    private static String hash(Path file) throws IOException {
        MessageDigest digest = sha256();
        try (InputStream input = Files.newInputStream(file)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    private static MessageDigest sha256() {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) text.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return text.toString();
    }

    private static boolean isEmpty(Path directory) throws IOException {
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(directory)) {
            return !stream.iterator().hasNext();
        }
    }

    private static final class Operation {
        final Path source;
        final Path target;
        final String relative;
        final boolean existed;
        Path backup;
        String originalHash;
        String status = "pending";
        boolean attempted;
        Operation(Path source, Path target, String relative, boolean existed) {
            this.source = source; this.target = target; this.relative = relative; this.existed = existed;
        }
    }
}
