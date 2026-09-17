package org.worldbank.suso;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Focused real-socket tests for transfer integrity, retry bounds and client reuse.
 * HTTPS redirect policy is inspected directly; this is not an end-to-end TLS test.
 */
public final class HttpTransferRegressionTest {
    private static int groups;
    private static final byte[] PREVIOUS = "previous complete local export".getBytes(StandardCharsets.UTF_8);

    private HttpTransferRegressionTest() { }

    public static void main(String[] args) throws Exception {
        testTransportAndRedirectPolicy();
        testClientConfigurationIsolation();
        try (Fixture fixture = new Fixture()) {
            testConnectionReuse(fixture);
            testSuccessfulDownload(fixture);
            testRejectedDownloads(fixture);
            testSafeGetRetries(fixture);
            testNoPostRetry(fixture);
            testBoundedRetries(fixture);
            testBodyTimeoutDoesNotRetry(fixture);
            testOneDeadlineAcrossRetries(fixture);
            testIndependentRedirectBudgets(fixture);
        }
        System.out.println("PASS HttpTransferRegressionTest (" + groups + " groups)");
    }

    private static void testTransportAndRedirectPolicy() throws Exception {
        try (Fixture fixture = new Fixture()) {
            AtomicInteger hits = new AtomicInteger();
            fixture.server.createContext("/credential-test", exchange -> {
                hits.incrementAndGet();
                respond(exchange, 200, "text/plain", new byte[]{'x'});
            });
            Http.Result blocked = Http.request("GET", fixture.url("/credential-test"),
                    "Basic dGVzdDpzZWNyZXQ=", "", "", "", 1000, 500,
                    "", 0, "", "", false, "");
            check(blocked.error != null && hits.get() == 0,
                    "credentials were allowed onto plaintext HTTP");
            Http.Result nonlocal = Http.request("GET", "http://example.invalid/export", "", "", "", "",
                    1000, 500, "", 0, "", "", false, "");
            check(nonlocal.error != null && !nonlocal.error.contains("ConnectException")
                            && !nonlocal.error.contains("UnresolvedAddressException"),
                    "nonlocal plaintext HTTP was not rejected before networking: " + nonlocal.error);
            Http.Result hostname = Http.request("GET", fixture.url("/credential-test").replace("127.0.0.1", "localhost"),
                    "", "", "", "", 1000, 500, "", 0, "", "", false, "");
            check(hostname.error != null && hits.get() == 0,
                    "plaintext development exception was broader than literal loopback");
            Path target = fixture.directory.resolve("insecure.bin");
            Files.write(target, PREVIOUS);
            Http.Result insecure = Http.request("GET", fixture.url("/credential-test"), "", "", "", "",
                    1000, 500, "", 0, "", "", true, target.toString());
            check(insecure.error != null && hits.get() == 0,
                    "file download allowed certificate verification to be disabled");
            check(Arrays.equals(PREVIOUS, Files.readAllBytes(target)),
                    "rejected insecure download changed the previous file");
        }
        URI original = URI.create("https://survey.example.org/api/export");
        String secret = "Basic dGVzdDpzZWNyZXQ=";
        HttpRequest current = HttpRequest.newBuilder(original).timeout(Duration.ofSeconds(1))
                .header("Authorization", secret).GET().build();
        HttpRequest same = redirected(current, original, URI.create("https://survey.example.org:443/files/export"), secret, 302);
        check(secret.equals(same.headers().firstValue("Authorization").orElse("")),
                "same-origin HTTPS redirect lost authorization");
        HttpRequest otherHost = redirected(current, original, URI.create("https://storage.example.org/export"), secret, 302);
        check(otherHost.headers().firstValue("Authorization").isEmpty(),
                "cross-origin redirect leaked authorization");
        HttpRequest otherPort = redirected(current, original, URI.create("https://survey.example.org:444/export"), secret, 302);
        check(otherPort.headers().firstValue("Authorization").isEmpty(),
                "different-port redirect leaked authorization");
        try {
            redirected(current, original, URI.create("http://127.0.0.1/export"), secret, 302);
            throw new AssertionError("HTTPS-to-HTTP redirect was accepted");
        } catch (InvocationTargetException expected) {
            check(expected.getCause() instanceof Exception,
                    "downgrade rejection did not produce an ordinary request failure");
        }
        HttpRequest post = HttpRequest.newBuilder(original).timeout(Duration.ofSeconds(1))
                .header("Authorization", secret).header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString("{\"private\":true}")).build();
        try {
            redirected(post, original, URI.create("https://storage.example.org/collect"), secret, 307);
            throw new AssertionError("cross-origin POST redirect exposed the request body");
        } catch (InvocationTargetException expected) {
            check(expected.getCause() instanceof Exception,
                    "cross-origin POST rejection did not produce an ordinary request failure");
        }
        HttpRequest seeOther = redirected(post, original, URI.create("https://storage.example.org/result"), secret, 303);
        check("GET".equals(seeOther.method()) && seeOther.headers().firstValue("Authorization").isEmpty()
                        && seeOther.headers().firstValue("Content-Type").isEmpty()
                        && seeOther.bodyPublisher().map(body -> body.contentLength() == 0).orElse(true),
                "303 redirect retained a private POST body, authorization, or content type");
        groups++;
    }

    private static void testClientConfigurationIsolation() throws Exception {
        Method factory = Http.class.getDeclaredMethod("client", int.class, String.class,
                int.class, String.class, String.class, boolean.class);
        factory.setAccessible(true);
        Object first = factory.invoke(null, 1222, "", 0, "", "", false);
        check(first instanceof HttpClient, "client factory returned no HttpClient");
        Object again = factory.invoke(null, 1222, "", 0, "", "", false);
        Object otherTimeout = factory.invoke(null, 1223, "", 0, "", "", false);
        Object insecure = factory.invoke(null, 1222, "", 0, "", "", true);
        check(first == again, "identical configurations did not reuse a client");
        check(first != otherTimeout, "connect-timeout change reused stale configuration");
        check(first != insecure, "insecure client was shared with verified TLS requests");
        // Proxy credentials must participate in the cache identity; no proxy request is sent.
        Object proxyA = factory.invoke(null, 1222, "127.0.0.1", 11999, "alice", "one", false);
        Object proxyB = factory.invoke(null, 1222, "127.0.0.1", 11999, "alice", "two", false);
        Object proxyC = factory.invoke(null, 1222, "127.0.0.1", 11999, "bob", "one", false);
        check(proxyA != proxyB && proxyA != proxyC, "proxy credentials shared stale authentication state");
        groups++;
    }

    private static void testConnectionReuse(Fixture fixture) throws Exception {
        Set<Integer> ports = ConcurrentHashMap.newKeySet();
        fixture.server.createContext("/reuse", exchange -> {
            ports.add(exchange.getRemoteAddress().getPort());
            respond(exchange, 200, "text/plain", new byte[]{'o', 'k'});
        });
        for (int i = 0; i < 5; i++) {
            Http.Result result = request(fixture, "GET", "/reuse", "", 3000, "", 1789);
            check(result.status == 200 && result.error == null, "connection reuse request failed");
        }
        check(ports.size() == 1, "five sequential requests opened " + ports.size() + " connections");
        Http.Result changed = request(fixture, "GET", "/reuse", "", 3000, "", 1790);
        check(changed.status == 200 && ports.size() == 2,
                "changed connect timeout did not create an isolated connection pool");
        groups++;
    }

    private static void testSuccessfulDownload(Fixture fixture) throws Exception {
        byte[] zip = storedZip("export.tab", "interview__id\tvalue\n1\t10\n");
        fixture.server.createContext("/complete", exchange -> respond(exchange, 200, "application/zip", zip));
        Path target = fixture.directory.resolve("export.zip");
        Files.write(target, PREVIOUS);
        Http.Result result = request(fixture, "GET", "/complete", target.toString(), 3000, "application/zip", 1500);
        check(result.status == 200 && result.error == null, "complete ZIP was rejected: " + result.error);
        check(Arrays.equals(zip, Files.readAllBytes(target)), "saved ZIP differs from the received bytes");
        check(result.bytes == zip.length && target.toAbsolutePath().toString().equals(result.savedPath),
                "successful transfer byte count or saved path is wrong");
        check(hex(MessageDigest.getInstance("SHA-256").digest(zip)).equals(stringField(result, "sha256")),
                "download SHA-256 does not match the saved file");
        check(numberField(result, "attempts").intValue() == 1, "successful download attempt count is wrong");
        check(numberField(result, "elapsedSeconds").doubleValue() >= 0.0,
                "successful download elapsed time is negative");
        fixture.assertNoPartialFiles();
        groups++;
    }

    private static void testRejectedDownloads(Fixture fixture) throws Exception {
        byte[] zip = storedZip("export.tab", "interview__id\tvalue\n1\t10\n");
        fixture.server.createContext("/empty", exchange -> respond(exchange, 200, "application/octet-stream", new byte[0]));
        fixture.server.createContext("/nocontent", exchange -> respond(exchange, 204, "application/zip", new byte[0]));
        fixture.server.createContext("/partial", exchange -> respond(exchange, 206, "application/zip", zip));
        fixture.server.createContext("/created", exchange -> respond(exchange, 201, "application/zip", zip));
        fixture.server.createContext("/notfound", exchange -> respond(exchange, 404, "text/plain", "missing".getBytes(StandardCharsets.UTF_8)));
        fixture.server.createContext("/login", exchange -> respond(exchange, 200, "text/html",
                "<!doctype html><title>Sign in</title>".getBytes(StandardCharsets.UTF_8)));
        fixture.server.createContext("/zip-labelled-html", exchange -> respond(exchange, 200, "application/zip",
                "<!doctype html><title>Sign in</title>".getBytes(StandardCharsets.UTF_8)));
        fixture.server.createContext("/truncated-zip", exchange -> respond(exchange, 200, "application/zip", Arrays.copyOf(zip, zip.length - 18)));
        byte[] misleadingComment = Arrays.copyOf(zip, zip.length + 22);
        misleadingComment[zip.length - 2] = 22;
        misleadingComment[zip.length] = 0x50;
        misleadingComment[zip.length + 1] = 0x4b;
        misleadingComment[zip.length + 2] = 0x05;
        misleadingComment[zip.length + 3] = 0x06;
        fixture.server.createContext("/false-empty-zip", exchange -> respond(exchange, 200, "application/zip", misleadingComment));
        fixture.server.createContext("/short-body", exchange -> {
            try {
                exchange.getResponseHeaders().set("Content-Type", "application/zip");
                exchange.sendResponseHeaders(200, zip.length + 7);
                exchange.getResponseBody().write(zip);
            } finally { exchange.close(); }
        });
        fixture.server.createContext("/redirect-without-location", exchange -> respond(exchange, 302, "text/plain", new byte[]{'x'}));
        Path target = fixture.directory.resolve("preserved.zip");
        for (String path : Arrays.asList("/empty", "/nocontent", "/partial", "/created", "/notfound", "/login",
                "/zip-labelled-html", "/truncated-zip", "/false-empty-zip", "/short-body", "/redirect-without-location")) {
            Files.write(target, PREVIOUS);
            Http.Result result = request(fixture, "GET", path, target.toString(), 600, "application/zip", 1500);
            check(result.error != null || result.status != 200,
                    "invalid download was reported successful at " + path);
            check(result.savedPath == null || result.savedPath.isEmpty(), "failed download exposed a saved path at " + path);
            check(Arrays.equals(PREVIOUS, Files.readAllBytes(target)), "failed download changed the existing file at " + path);
            fixture.assertNoPartialFiles();
        }
        // A server ZIP content type must also trigger ZIP validation with a generic Accept header.
        Files.write(target, PREVIOUS);
        Http.Result generic = request(fixture, "GET", "/zip-labelled-html", target.toString(), 1000, "*/*", 1500);
        check(generic.error != null && Arrays.equals(PREVIOUS, Files.readAllBytes(target)),
                "application/zip content type bypassed archive validation under generic Accept");
        fixture.assertNoPartialFiles();
        groups++;
    }

    private static void testSafeGetRetries(Fixture fixture) throws Exception {
        byte[] zip = storedZip("data.tab", "id\tx\n1\t7\n");
        for (int transientStatus : new int[]{429, 502, 503, 504}) {
            AtomicInteger hits = new AtomicInteger();
            String path = "/retry-" + transientStatus;
            fixture.server.createContext(path, exchange -> {
                exchange.getResponseHeaders().set("Retry-After", "0");
                if (hits.incrementAndGet() < 3) respond(exchange, transientStatus, "text/plain", new byte[]{'x'});
                else respond(exchange, 200, "application/zip", zip);
            });
            Path target = fixture.directory.resolve("retried-" + transientStatus + ".zip");
            Files.write(target, PREVIOUS);
            Http.Result result = request(fixture, "GET", path, target.toString(), 5000, "application/zip", 1500);
            check(result.status == 200 && result.error == null && hits.get() == 3,
                    "GET did not recover after two " + transientStatus + " replies: " + result.error);
            check(numberField(result, "attempts").intValue() == 3, "retry count was not recorded");
            check(Arrays.equals(zip, Files.readAllBytes(target)), "retry did not save the complete final response");
            check(hex(MessageDigest.getInstance("SHA-256").digest(zip)).equals(stringField(result, "sha256")),
                    "retry digest included bytes from a previous failed response");
            fixture.assertNoPartialFiles();
        }
        groups++;
    }

    private static void testNoPostRetry(Fixture fixture) throws Exception {
        AtomicInteger hits = new AtomicInteger();
        fixture.server.createContext("/no-post-retry", exchange -> {
            hits.incrementAndGet();
            exchange.getResponseHeaders().set("Retry-After", "0");
            respond(exchange, 503, "text/plain", new byte[]{'x'});
        });
        Http.Result text = request(fixture, "POST", "/no-post-retry", "", 2000, "", 1500);
        check(text.status == 503 && hits.get() == 1 && numberField(text, "attempts").intValue() == 1,
                "POST text request was replayed automatically");
        Http.Result bytes = Http.requestBytes("POST", fixture.url("/no-post-retry"), "",
                new byte[]{1, 2, 3}, "application/octet-stream", "", 1500, 2000,
                "", 0, "", "", false);
        check(bytes.status == 503 && hits.get() == 2 && numberField(bytes, "attempts").intValue() == 1,
                "POST byte request was replayed automatically");
        groups++;
    }

    private static void testBoundedRetries(Fixture fixture) throws Exception {
        AtomicInteger hits = new AtomicInteger();
        fixture.server.createContext("/always-busy", exchange -> {
            hits.incrementAndGet();
            exchange.getResponseHeaders().set("Retry-After", "0");
            respond(exchange, 503, "text/plain", new byte[]{'x'});
        });
        Path target = fixture.directory.resolve("busy.zip");
        Files.write(target, PREVIOUS);
        Http.Result result = request(fixture, "GET", "/always-busy", target.toString(), 5000, "application/zip", 1500);
        check(hits.get() == 3 && numberField(result, "attempts").intValue() == 3,
                "GET retry cap was not exactly two retries");
        check(Arrays.equals(PREVIOUS, Files.readAllBytes(target)), "exhausted retries replaced the existing export");
        AtomicInteger longWaitHits = new AtomicInteger();
        fixture.server.createContext("/long-retry-after", exchange -> {
            longWaitHits.incrementAndGet();
            exchange.getResponseHeaders().set("Retry-After", "60");
            respond(exchange, 429, "text/plain", new byte[]{'x'});
        });
        long started = System.nanoTime();
        Http.Result wait = request(fixture, "GET", "/long-retry-after", target.toString(), 250, "application/zip", 1500);
        long elapsed = (System.nanoTime() - started) / 1_000_000L;
        check(elapsed < 1500 && longWaitHits.get() == 1,
                "Retry-After escaped the overall deadline or was ignored: " + elapsed + "ms / " + longWaitHits.get());
        check(wait.error != null || wait.status != 200, "rate-limited request reported success");
        check(Arrays.equals(PREVIOUS, Files.readAllBytes(target)), "Retry-After failure replaced the existing export");
        fixture.assertNoPartialFiles();
        groups++;
    }

    private static void testBodyTimeoutDoesNotRetry(Fixture fixture) throws Exception {
        AtomicInteger hits = new AtomicInteger();
        fixture.server.createContext("/slow-body", exchange -> {
            hits.incrementAndGet();
            try {
                exchange.sendResponseHeaders(200, 2);
                exchange.getResponseBody().write('a');
                exchange.getResponseBody().flush();
                Thread.sleep(2000);
                exchange.getResponseBody().write('b');
            } catch (IOException ignored) { }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            finally { exchange.close(); }
        });
        Path target = fixture.directory.resolve("timeout.bin");
        Files.write(target, PREVIOUS);
        long started = System.nanoTime();
        Http.Result result = request(fixture, "GET", "/slow-body", target.toString(), 250, "application/octet-stream", 1500);
        long elapsed = (System.nanoTime() - started) / 1_000_000L;
        check(result.error != null && result.error.toLowerCase().contains("tim") && elapsed < 1500,
                "body timeout did not bound the complete transfer: " + elapsed + "ms / " + result.error);
        check(hits.get() == 1 && numberField(result, "attempts").intValue() == 1,
                "timeout triggered an automatic replay");
        check(Arrays.equals(PREVIOUS, Files.readAllBytes(target)), "timeout replaced the existing file");
        fixture.assertNoPartialFiles();
        groups++;
    }

    private static void testOneDeadlineAcrossRetries(Fixture fixture) throws Exception {
        AtomicInteger hits = new AtomicInteger();
        fixture.server.createContext("/delayed-retries", exchange -> {
            int attempt = hits.incrementAndGet();
            try {
                Thread.sleep(130);
                exchange.getResponseHeaders().set("Retry-After", "0");
                respond(exchange, attempt < 3 ? 503 : 200, "text/plain", new byte[]{'x'});
            } catch (IOException ignored) { }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            finally { exchange.close(); }
        });
        long started = System.nanoTime();
        Http.Result result = request(fixture, "GET", "/delayed-retries", "", 250, "", 1500);
        long elapsed = (System.nanoTime() - started) / 1_000_000L;
        check(result.error != null && elapsed < 1200 && hits.get() < 3,
                "retries restarted the request deadline: " + elapsed + "ms / " + hits.get() + " attempts");
        groups++;
    }

    private static void testIndependentRedirectBudgets(Fixture fixture) throws Exception {
        AtomicInteger hits = new AtomicInteger();
        fixture.server.createContext("/delayed-chain", exchange -> {
            int hop = hits.incrementAndGet();
            try {
                Thread.sleep(130);
                if (hop < 3) {
                    exchange.getResponseHeaders().set("Location", "/delayed-chain");
                    respond(exchange, 302, "text/plain", new byte[]{'x'});
                } else respond(exchange, 200, "text/plain", new byte[]{'o', 'k'});
            } catch (IOException ignored) { }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            finally { exchange.close(); }
        });
        long started = System.nanoTime();
        Http.Result result = request(fixture, "GET", "/delayed-chain", "", 250, "", 1500);
        long elapsed = (System.nanoTime() - started) / 1_000_000L;
        check(result.status == 200 && result.error == null && elapsed > 300 && hits.get() == 3,
                "redirect hops did not receive their documented independent budgets: " + elapsed + "ms / " + hits.get() + " hops / " + result.error);
        groups++;
    }

    private static Http.Result request(Fixture fixture, String method, String path, String savePath,
            int readTimeout, String accept, int connectTimeout) {
        return Http.request(method, fixture.url(path), "", "", "", accept, connectTimeout,
                readTimeout, "", 0, "", "", false, savePath);
    }

    private static HttpRequest redirected(HttpRequest current, URI original, URI target,
            String authorization, int status) throws Exception {
        Method method = Http.class.getDeclaredMethod("redirected", HttpRequest.class, URI.class,
                URI.class, String.class, int.class);
        method.setAccessible(true);
        return (HttpRequest) method.invoke(null, current, original, target, authorization, status);
    }

    private static Number numberField(Http.Result result, String name) throws Exception {
        Object value = Http.Result.class.getField(name).get(result);
        check(value instanceof Number, "transfer result field " + name + " is not numeric");
        return (Number) value;
    }

    private static String stringField(Http.Result result, String name) throws Exception {
        return String.valueOf(Http.Result.class.getField(name).get(result));
    }

    private static byte[] storedZip(String filename, String content) throws IOException {
        byte[] bytes = content.getBytes(StandardCharsets.UTF_8);
        CRC32 crc = new CRC32();
        crc.update(bytes);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(out)) {
            ZipEntry entry = new ZipEntry(filename);
            entry.setMethod(ZipEntry.STORED);
            entry.setSize(bytes.length);
            entry.setCompressedSize(bytes.length);
            entry.setCrc(crc.getValue());
            zip.putNextEntry(entry);
            zip.write(bytes);
            zip.closeEntry();
        }
        return out.toByteArray();
    }

    private static String hex(byte[] bytes) {
        StringBuilder value = new StringBuilder();
        for (byte b : bytes) value.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
        return value.toString();
    }

    private static void respond(HttpExchange exchange, int status, String type, byte[] bytes) throws IOException {
        try {
            exchange.getResponseHeaders().set("Content-Type", type);
            exchange.sendResponseHeaders(status, bytes.length == 0 ? -1 : bytes.length);
            if (bytes.length > 0) exchange.getResponseBody().write(bytes);
        } finally { exchange.close(); }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static final class Fixture implements AutoCloseable {
        final HttpServer server;
        final ExecutorService executor = Executors.newCachedThreadPool();
        final Path directory = Files.createTempDirectory("suso-transfer-test-");

        Fixture() throws IOException {
            server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            server.setExecutor(executor);
            server.start();
        }

        String url(String path) { return "http://127.0.0.1:" + server.getAddress().getPort() + path; }

        void assertNoPartialFiles() throws IOException {
            try (Stream<Path> paths = Files.list(directory)) {
                check(paths.noneMatch(path -> path.getFileName().toString().endsWith(".part")),
                        "failed or completed transfer left a partial file behind");
            }
        }

        @Override public void close() throws IOException {
            server.stop(0);
            executor.shutdownNow();
            try (Stream<Path> paths = Files.walk(directory)) {
                for (Path path : (Iterable<Path>) paths.sorted(Comparator.reverseOrder())::iterator) {
                    Files.deleteIfExists(path);
                }
            }
        }
    }
}
