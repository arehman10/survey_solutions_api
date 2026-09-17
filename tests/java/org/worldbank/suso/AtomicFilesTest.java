package org.worldbank.suso;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.file.AccessDeniedException;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;

/** Deterministic lock-denial probes; no Windows/SMB environment is simulated. */
public final class AtomicFilesTest {
    private static int checks;
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
        checks++;
    }

    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("suso-atomic-test-");
        try {
            Path source = root.resolve("source");
            Path target = root.resolve("target");
            Files.writeString(source, "verified new bytes");
            Files.writeString(target, "original bytes");
            List<Long> delays = new ArrayList<>();
            int[] calls = {0};
            AtomicFiles.move(source, target, (from, to) -> {
                check("original bytes".equals(Files.readString(to)), "old target retained until rename succeeds");
                if (++calls[0] < 3) throw new AccessDeniedException(from.toString(), to.toString(), null);
                Files.move(from, to, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            }, delays::add);
            check(calls[0] == 3 && delays.equals(List.of(50L, 100L)), "temporary denial is retried with backoff");
            check("verified new bytes".equals(Files.readString(target)) && !Files.exists(source), "successful rename publishes all bytes");

            Files.writeString(source, "retry source");
            String prior = Files.readString(target);
            calls[0] = 0;
            delays.clear();
            try {
                AtomicFiles.move(source, target, (from, to) -> {
                    calls[0]++;
                    throw new AccessDeniedException(from.toString(), to.toString(), "permanent denial");
                }, delays::add);
                throw new AssertionError("permanent denial must fail");
            } catch (AccessDeniedException expected) {
                check(calls[0] == 6, "permanent denial has exactly six attempts");
                check(delays.equals(List.of(50L, 100L, 200L, 400L, 800L)), "retry waits bounded to 1550ms");
                check(prior.equals(Files.readString(target)), "failed replacement never deletes prior target");
                check("retry source".equals(Files.readString(source)), "failed replacement retains verified source");
            }

            for (IOException failure : List.of(new AtomicMoveNotSupportedException("source", "target", "unsupported"),
                    new IOException("storage failure"))) {
                calls[0] = 0;
                delays.clear();
                try {
                    AtomicFiles.move(source, target, (from, to) -> { calls[0]++; throw failure; }, delays::add);
                    throw new AssertionError("non-lock failure must propagate");
                } catch (IOException expected) {
                    check(expected == failure && calls[0] == 1 && delays.isEmpty(), "non-lock failures are not retried or weakened");
                }
            }

            calls[0] = 0;
            try {
                AtomicFiles.move(source, target, (from, to) -> {
                    calls[0]++;
                    throw new AccessDeniedException(from.toString());
                }, millis -> { throw new InterruptedException("stop"); });
                throw new AssertionError("interruption must stop retries");
            } catch (InterruptedIOException expected) {
                check(calls[0] == 1 && Thread.currentThread().isInterrupted(), "retry cancellation preserves interrupt flag");
            } finally { Thread.interrupted(); }

            Thread.currentThread().interrupt();
            calls[0] = 0;
            try {
                AtomicFiles.move(source, target, (from, to) -> { calls[0]++; }, delays::add);
                throw new AssertionError("preexisting cancellation must stop publication");
            } catch (InterruptedIOException expected) {
                check(calls[0] == 0, "cancelled operation does not publish");
            } finally { Thread.interrupted(); }

            AtomicFiles.move(source, target);
            check("retry source".equals(Files.readString(target)), "production mover atomically replaces an existing file");
            Files.writeString(source, "fresh publication");
            try {
                AtomicFiles.moveNew(source, target);
                throw new AssertionError("fresh publication must reject an existing name");
            } catch (java.nio.file.FileAlreadyExistsException expected) {
                check("retry source".equals(Files.readString(target)), "fresh publication never replaces an existing name");
            }
            Path fresh = root.resolve("fresh");
            AtomicFiles.moveNew(source, fresh);
            check("fresh publication".equals(Files.readString(fresh)), "fresh atomic publication writes new target");
            System.out.println("PASS AtomicFilesTest: " + checks + " assertions");
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
                for (Path path : (Iterable<Path>) paths.sorted(java.util.Comparator.reverseOrder())::iterator) Files.deleteIfExists(path);
            }
        }
    }
}
