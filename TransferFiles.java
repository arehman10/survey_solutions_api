package org.worldbank.suso;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;

/** Local publication of verified downloads; never discards a previous file. */
final class TransferFiles {
    private TransferFiles() {}

    static String publish(Path temporary, Path destination) throws IOException {
        Path temp = temporary.toAbsolutePath().normalize();
        Path target = destination.toAbsolutePath().normalize();
        if (!temp.getParent().equals(target.getParent()) || temp.equals(target)) {
            throw new IOException("Download staging must be beside its destination");
        }
        if (!Files.isRegularFile(temp, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Download staging file is not a regular file");
        }
        force(temp);
        Path previous = null;
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS)) {
                throw new IOException("Refusing to replace a directory or symbolic link: " + target);
            }
            // This is an independent copy, not a hard link to a file another
            // process could still edit. The old target stays in place until
            // the final atomic rename succeeds.
            previous = Files.createTempFile(target.getParent(), ".suso-previous-", ".backup");
            boolean copied = false;
            try {
                Files.copy(target, previous, StandardCopyOption.REPLACE_EXISTING,
                        LinkOption.NOFOLLOW_LINKS);
                if (!Files.isRegularFile(previous, LinkOption.NOFOLLOW_LINKS)
                        || Files.size(previous) != Files.size(target)) {
                    throw new IOException("Previous file changed while preserving it: " + target);
                }
                force(previous);
                copied = true;
            } finally {
                if (!copied) Files.deleteIfExists(previous);
            }
        }
        try {
            try {
                AtomicFiles.move(temp, target);
            } catch (AtomicMoveNotSupportedException unavailable) {
                if (previous != null) {
                    throw new IOException("This filesystem cannot atomically replace the download; "
                            + "use a new saving() filename. Previous file remains in place.", unavailable);
                }
                Files.move(temp, target);
            }
        } catch (IOException failure) {
            if (previous != null) {
                throw new IOException(failure.getMessage() + " Preserved previous copy: "
                        + previous, failure);
            }
            throw failure;
        }
        return previous == null ? "" : previous.toString();
    }

    private static void force(Path path) throws IOException {
        try (FileChannel channel = FileChannel.open(path, StandardOpenOption.WRITE)) {
            channel.force(true);
        }
    }
}
