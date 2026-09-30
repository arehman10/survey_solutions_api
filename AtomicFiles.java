package org.worldbank.suso;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.nio.file.AccessDeniedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/** Atomic publication with a short retry budget for temporary file locks.
 * Windows scanners and network shares can briefly deny a rename. The original
 * target stays in place on denial; no deletion or copy fallback is permitted.
 */
final class AtomicFiles {
    private static final long[] DELAYS_MS = {50, 100, 200, 400, 800};

    @FunctionalInterface
    interface Mover { void move(Path from, Path to) throws IOException; }
    @FunctionalInterface
    interface Pauser { void pause(long millis) throws InterruptedException; }

    private AtomicFiles() {}

    static void move(Path from, Path to) throws IOException {
        move(from, to, (source, target) -> Files.move(source, target,
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING),
                Thread::sleep);
    }

    /** Fresh publication inside a directory already owned by this transaction. */
    static void moveNew(Path from, Path to) throws IOException {
        move(from, to, (source, target) -> {
            if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
                throw new FileAlreadyExistsException(target.toString());
            }
            Files.move(source, target, StandardCopyOption.ATOMIC_MOVE);
        }, Thread::sleep);
    }

    static void move(Path from, Path to, Mover mover, Pauser pauser) throws IOException {
        for (int attempt = 0; ; attempt++) {
            if (Thread.currentThread().isInterrupted()) throw interrupted(null);
            try {
                mover.move(from, to);
                return;
            } catch (AccessDeniedException denied) {
                if (attempt >= DELAYS_MS.length) throw denied;
                try { pauser.pause(DELAYS_MS[attempt]); }
                catch (InterruptedException stopped) {
                    Thread.currentThread().interrupt();
                    throw interrupted(stopped);
                }
            }
        }
    }

    private static InterruptedIOException interrupted(Throwable cause) {
        InterruptedIOException error = new InterruptedIOException("Atomic file publication interrupted");
        if (cause != null) error.initCause(cause);
        return error;
    }
}
