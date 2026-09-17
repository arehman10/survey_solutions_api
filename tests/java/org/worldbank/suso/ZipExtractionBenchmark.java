package org.worldbank.suso;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;

/** Same harness runs with either the old or new JAR first on the classpath. */
public final class ZipExtractionBenchmark {
    public static void main(String[] args) throws Exception {
        if (args.length != 4) throw new IllegalArgumentException("archive parent password expected-sha256");
        Path parent = Path.of(args[1]);
        Files.createDirectories(parent);
        double[] times = new double[5];
        for (int i = -1; i < times.length; i++) {
            Path destination = parent.resolve("iteration-" + i);
            long start = System.nanoTime();
            Zip.Result result = Zip.extract(args[0], destination.toString(), args[2]);
            double seconds = (System.nanoTime() - start) / 1_000_000_000.0;
            if (result.error != null || result.files != 1) throw new AssertionError(result.error);
            MessageDigest hash = MessageDigest.getInstance("SHA-256");
            try (InputStream in = Files.newInputStream(Path.of(result.dir).resolve(result.names.get(0)))) {
                byte[] buffer = new byte[65536]; int n;
                while ((n = in.read(buffer)) >= 0) hash.update(buffer, 0, n);
            }
            StringBuilder hex = new StringBuilder();
            for (byte b : hash.digest()) hex.append(String.format("%02x", b & 255));
            if (!args[3].contentEquals(hex)) throw new AssertionError("plaintext SHA-256 mismatch");
            if (i >= 0) times[i] = seconds;
            try (java.util.stream.Stream<Path> paths = Files.walk(Path.of(result.dir))) {
                for (Path path : (Iterable<Path>)paths.sorted(java.util.Comparator.reverseOrder())::iterator) Files.delete(path);
            }
        }
        double[] sorted = times.clone(); Arrays.sort(sorted);
        System.out.println("seconds=" + Arrays.toString(times) + "; median=" + sorted[2] + "; all plaintext SHA-256 hashes verified");
    }
}
