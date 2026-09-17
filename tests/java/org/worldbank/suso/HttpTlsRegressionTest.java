package org.worldbank.suso;

import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.InputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/** Live local TLS checks. Takes a test PKCS12 keystore created by run-http-tls.sh. */
public final class HttpTlsRegressionTest {
    private HttpTlsRegressionTest() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 1) throw new IllegalArgumentException("Provide the generated test PKCS12 path");
        KeyStore keys = KeyStore.getInstance("PKCS12");
        char[] testPassword = "suso-test-only".toCharArray();
        try (InputStream in = Files.newInputStream(Path.of(args[0]))) { keys.load(in, testPassword); }
        KeyManagerFactory km = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        km.init(keys, testPassword);
        TrustManagerFactory tm = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tm.init(keys);
        SSLContext serverTls = SSLContext.getInstance("TLS");
        serverTls.init(km.getKeyManagers(), tm.getTrustManagers(), null);
        SSLContext trusted = SSLContext.getInstance("TLS");
        trusted.init(null, tm.getTrustManagers(), null);
        SSLContext original = SSLContext.getDefault();
        HttpsServer server = HttpsServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.setHttpsConfigurator(new HttpsConfigurator(serverTls));
        AtomicInteger calls = new AtomicInteger();
        AtomicReference<String> auth = new AtomicReference<>();
        server.createContext("/file", exchange -> {
            calls.incrementAndGet();
            auth.set(exchange.getRequestHeaders().getFirst("Authorization"));
            byte[] value = "verified-tls-content".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, value.length);
            exchange.getResponseBody().write(value);
            exchange.close();
        });
        server.createContext("/downgrade", exchange -> {
            exchange.getResponseHeaders().add("Location", "http://127.0.0.1:" + server.getAddress().getPort() + "/file");
            exchange.sendResponseHeaders(302, -1);
            exchange.close();
        });
        server.start();
        Path directory = Files.createTempDirectory("suso-tls-test-");
        Path file = directory.resolve("saved.bin");
        List<String> backups = new ArrayList<>();
        String base = "https://localhost:" + server.getAddress().getPort();
        try {
            Files.writeString(file, "prior-content");
            Http.Result untrusted = get(base + "/file?token=test-signed-secret", "Bearer test-only", false, file);
            check(untrusted.error != null && untrusted.error.contains("SSLHandshakeException"),
                    "self-signed certificate was trusted: " + untrusted.error);
            check(!untrusted.error.contains("test-signed-secret"), "TLS error leaked signed URL query");
            check("prior-content".equals(Files.readString(file)) && calls.get() == 0,
                    "untrusted TLS replaced file or reached request handler");

            Http.Result bypass = get(base + "/file", "Bearer test-only", true, file);
            check(bypass.error != null && bypass.error.contains("verified TLS") && bypass.attempts == 0,
                    "insecure download mode was accepted");

            // Changing the default trust context must select a different cached
            // client; an earlier untrusted client must not poison later requests.
            SSLContext.setDefault(trusted);
            Http.Result ok = get(base + "/file", "Bearer first-test-token", false, file);
            check(ok.error == null && ok.status == 200, "trusted TLS download failed: " + ok.error);
            backups.add(ok.backupPath);
            check("verified-tls-content".equals(Files.readString(file)), "trusted TLS bytes differ");
            check("Bearer first-test-token".equals(auth.get()), "authenticated HTTPS header missing");
            check("prior-content".equals(Files.readString(Path.of(ok.backupPath))), "prior content backup differs");

            Http.Result otherAuth = get(base + "/file", "Bearer second-test-token", false, file);
            check(otherAuth.error == null && "Bearer second-test-token".equals(auth.get()),
                    "cached client reused earlier Authorization header");
            backups.add(otherAuth.backupPath);
            Http.Result noAuth = get(base + "/file", "", false, file);
            check(noAuth.error == null && auth.get() == null,
                    "cached client sent credentials on unauthenticated request");
            backups.add(noAuth.backupPath);

            int before = calls.get();
            Http.Result badHost = get(base.replace("localhost", "127.0.0.1") + "/file", "Bearer test-only", false, file);
            check(badHost.error != null && calls.get() == before, "hostname mismatch was accepted");
            Http.Result downgrade = get(base + "/downgrade", "Bearer test-only", false, file);
            check(downgrade.error != null && downgrade.error.contains("downgrade"),
                    "HTTPS downgrade was accepted: " + downgrade.error);
            check("verified-tls-content".equals(Files.readString(file)), "failed TLS/redirect replaced destination");

            SSLContext.setDefault(original);
            Http.Result restored = get(base + "/file", "", false, file);
            check(restored.error != null, "trusted client crossed default TLS context change");
            System.out.println("PASS HttpTlsRegressionTest (untrusted CA, secure-mode enforcement, trusted TLS,"
                    + " per-request auth, hostname verification, downgrade rejection, TLS context isolation)");
        } finally {
            SSLContext.setDefault(original);
            server.stop(0);
            for (String backup : backups) if (backup != null && !backup.isEmpty()) Files.deleteIfExists(Path.of(backup));
            Files.deleteIfExists(file);
            Files.deleteIfExists(directory);
        }
    }

    private static Http.Result get(String url, String auth, boolean insecure, Path path) {
        return Http.request("GET", url, auth, "", "", "application/octet-stream",
                3000, 4000, "", 0, "", "", insecure, path.toString());
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
