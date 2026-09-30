import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarOutputStream;
import java.util.stream.Stream;

/** Package only SuSo classes, using stable ordering and timestamps. */
public final class BuildJar {
    public static void main(String[] args) throws Exception {
        Path classes = Path.of(args[0]);
        Path target = Path.of(args[1]);
        Path packageRoot = classes.resolve("org/worldbank/suso");
        if (!Files.isDirectory(packageRoot)) throw new IllegalArgumentException("No SuSo classes");
        List<Path> entries = new ArrayList<>();
        try (Stream<Path> paths = Files.walk(packageRoot)) {
            paths.filter(p -> Files.isRegularFile(p) && p.toString().endsWith(".class")).forEach(entries::add);
        }
        entries.sort(Comparator.comparing(p -> classes.relativize(p).toString()));
        Path temp = Files.createTempFile(target.toAbsolutePath().getParent(), ".suso-jar-", ".tmp");
        try {
            try (OutputStream out = Files.newOutputStream(temp); JarOutputStream jar = new JarOutputStream(out)) {
                for (Path path : entries) {
                    JarEntry entry = new JarEntry(classes.relativize(path).toString().replace('\\', '/'));
                    // ZIP timestamps have no timezone. Fixed local time ensures byte equality across zones.
                    entry.setTime(java.time.LocalDateTime.of(1980, 1, 1, 0, 0)
                            .atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli());
                    jar.putNextEntry(entry);
                    Files.copy(path, jar);
                    jar.closeEntry();
                }
            }
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temp); }
    }
}
