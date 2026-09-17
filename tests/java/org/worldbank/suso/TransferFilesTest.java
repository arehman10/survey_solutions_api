package org.worldbank.suso;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

/** Independent prior-file preservation and non-file destination checks. */
public final class TransferFilesTest {
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("suso-publication-test-");
        try {
            Path target = root.resolve("survey.zip");
            Path temp = Files.createTempFile(root, "incoming-", ".part");
            Files.writeString(temp, "first-complete-download");
            check(TransferFiles.publish(temp, target).isEmpty(), "first download made a prior backup");
            check(!Files.exists(temp), "staging left after publication");
            temp = Files.createTempFile(root, "incoming-", ".part");
            Files.writeString(temp, "second-complete-download");
            String backup = TransferFiles.publish(temp, target);
            check(Files.readString(Path.of(backup)).equals("first-complete-download"), "old file lost");
            check(Files.readString(target).equals("second-complete-download"), "new file not published");
            Files.writeString(target, "later-edit");
            check(Files.readString(Path.of(backup)).equals("first-complete-download"), "backup shares target data");

            Path directory = Files.createDirectory(root.resolve("existing-folder"));
            Files.writeString(directory.resolve("keep.txt"), "keep");
            temp = Files.createTempFile(root, "incoming-", ".part");
            Files.writeString(temp, "must-not-replace-folder");
            try { TransferFiles.publish(temp, directory); throw new AssertionError("folder overwritten"); }
            catch (IOException expected) { }
            check(Files.readString(directory.resolve("keep.txt")).equals("keep"), "folder contents lost");
            check(Files.exists(temp), "caller cannot clean failed staging");

            try {
                Path symlink = root.resolve("link.zip");
                Files.createSymbolicLink(symlink, target.getFileName());
                try { TransferFiles.publish(temp, symlink); throw new AssertionError("symlink overwritten"); }
                catch (IOException expected) { }
                check(Files.readString(target).equals("later-edit"), "symlink referent changed");
            } catch (UnsupportedOperationException ignored) { }
            System.out.println("PASS: download publication, independent previous copy, folder/symlink protection");
        } finally {
            try (java.util.stream.Stream<Path> paths = Files.walk(root)) {
                for (Path p : paths.sorted(java.util.Comparator.reverseOrder()).toArray(Path[]::new)) Files.delete(p);
            }
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
