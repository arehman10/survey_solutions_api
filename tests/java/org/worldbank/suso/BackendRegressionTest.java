package org.worldbank.suso;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.zip.CRC32;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public final class BackendRegressionTest {
    public static void main(String[] args) throws Exception {
        testZipContainmentAndAtomicity();
        if (args.length > 0) testEncryptedZip(Path.of(args[0]));
        if (args.length > 1) testQuestionnaireParser(Path.of(args[1]));
        if (args.length > 2) testTriStateQuestionnaireParser(Path.of(args[2]));
        testHttpRedirectsAndDownloads();
        testBodyTimeoutsAndCancellation();
        testCompleteOptionLists();
        testUtf8StringSizing();
        testSfiStatusCheck();
        System.out.println("PASS BackendRegressionTest");
    }

    private static void testCompleteOptionLists() throws Exception {
        StringBuilder html = new StringBuilder("<div class=\"question-container\"><div class=\"question-id\">1</div>"
                + "<div class=\"variable_name\">options61</div>"
                + "<div class=\"type\">Single-option</div>");
        for (int i = 1; i <= 61; i++) html.append("<div class=\"option-value\"><span>")
                .append(i).append("</span><label>Option ").append(i).append("</label></div>");
        html.append("</div>");
        Path file = Files.createTempFile("suso-61-options-", ".html");
        try {
            Files.writeString(file, html);
            List<Map<String, String>> rows = Qx.parse(file);
            check(rows.size() == 1, "61-option questionnaire row count: " + rows.size());
            Map<String, String> row = rows.get(0);
            check("61".equals(row.get("qx_nopts")), "61-option count");
            String[] values = row.get("qx_optvals").trim().split("\\s+");
            check(values.length == 61 && "61".equals(values[60]),
                    "option validation list was truncated: " + row.get("qx_optvals"));
            check(row.get("qx_optmap").contains("Option 61"), "option labels were truncated");
        } finally { Files.deleteIfExists(file); }
    }

    private static void testBodyTimeoutsAndCancellation() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        ExecutorService executor = Executors.newCachedThreadPool();
        server.setExecutor(executor);
        server.createContext("/stall", exchange -> {
            try {
                exchange.sendResponseHeaders(200, 2);
                exchange.getResponseBody().write('a');
                exchange.getResponseBody().flush();
                Thread.sleep(2200);
                exchange.getResponseBody().write('b');
            } catch (IOException | InterruptedException ignored) { }
            finally { exchange.close(); }
        });
        server.createContext("/headers", exchange -> {
            try { Thread.sleep(2200); respond(exchange, 200, "ok"); }
            catch (IOException | InterruptedException ignored) { }
            finally { exchange.close(); }
        });
        server.createContext("/ready", exchange -> respond(exchange, 200, "ready"));
        server.start();
        Path directory = Files.createTempDirectory("suso-timeout-test-");
        Path target = directory.resolve("existing.bin");
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            for (String path : List.of("/headers", "/stall")) {
                for (boolean file : List.of(false, true)) {
                    Files.writeString(target, "prior-download");
                    long start = System.nanoTime();
                    Http.Result result = Http.request("GET", base + path, "", "", "", "",
                            1000, 300, "", 0, "", "", false, file ? target.toString() : "");
                    long elapsed = (System.nanoTime() - start) / 1_000_000L;
                    check(result.status == 0 && result.error != null && result.error.contains("Timeout"),
                            "stalled " + path + " did not time out: " + result.error);
                    check(elapsed < 1600, "timeout failed to bound response body: " + elapsed + " ms");
                    check("prior-download".equals(Files.readString(target)),
                            "timed out download replaced existing target");
                    try (java.util.stream.Stream<Path> paths = Files.list(directory)) {
                        check(paths.noneMatch(p -> p.getFileName().toString().endsWith(".part")),
                                "cancelled download leaked a partial file");
                    }
                }
            }
            Http.Result after = Http.request("GET", base + "/ready", "", "", "", "",
                    1000, 1000, "", 0, "", "", false, target.toString());
            check(after.error == null && "ready".equals(Files.readString(target)),
                    "a successful download after cancellation failed");
            check("prior-download".equals(Files.readString(Path.of(after.backupPath))),
                    "successful replacement lost its independent prior download");
            Files.delete(Path.of(after.backupPath));
        } finally {
            server.stop(0);
            executor.shutdownNow();
            Files.deleteIfExists(target);
            Files.deleteIfExists(directory);
        }
    }

    private static void testSfiStatusCheck() {
        SfiCheck.ok(0);
        try {
            SfiCheck.ok(9);
            throw new AssertionError("nonzero SFI status was ignored");
        } catch (IllegalStateException expected) {
            check(expected.getMessage().contains("rc=9"), "SFI error lacks return code");
        }
    }

    private static void testQuestionnaireParser(Path questionnaire) throws Exception {
        List<Map<String, String>> rows = Qx.parse(questionnaire);
        check(rows.size() == 5, "questionnaire parser row count: " + rows.size());
        Map<String, Map<String, String>> byVar = new java.util.HashMap<>();
        for (Map<String, String> row : rows) byVar.put(row.get("qx_var"), row);
        for (String name : List.of("sc3a", "sc2", "b0", "b03", "b9_you")) {
            check(byVar.containsKey(name), "questionnaire parser missed " + name);
            check("blocklevel==1".equals(byVar.get(name).get("qx_section_enable")),
                    "section condition for " + name);
        }
        check("lf_responsive==1".equals(byVar.get("b9_you").get("qx_group_enable")),
                "group condition for b9_you");
        check("b0==1".equals(byVar.get("b9_you").get("qx_item_enable")),
                "item condition for b9_you");
        check(byVar.get("sc2").get("qx_enable").contains("confirm_informal==true"),
                "effective sc2 condition");
    }

    private static void testTriStateQuestionnaireParser(Path questionnaire)
            throws Exception {
        List<Map<String, String>> rows = Qx.parse(questionnaire);
        check(rows.size() == 4, "tri-state questionnaire row count: " + rows.size());
        Map<String, Map<String, String>> byVar = new java.util.HashMap<>();
        for (Map<String, String> row : rows) byVar.put(row.get("qx_var"), row);
        Map<String, String> orChild = byVar.get("or_child");
        Map<String, String> andChild = byVar.get("and_child");
        check(orChild != null && andChild != null,
                "tri-state questionnaire missed OR/AND child");
        check("a==1 || b+0>0".equals(orChild.get("qx_item_enable")),
                "OR source condition changed");
        check("a==1 && b+0>0".equals(andChild.get("qx_item_enable")),
                "AND source condition changed");
        String orTri = orChild.get("qx_item_tri");
        String andTri = andChild.get("qx_item_tri");
        check(orTri != null && orTri.startsWith("max(")
                        && orTri.contains("missing(b)") && orTri.contains(".5"),
                "OR tri-state translation lost nullable short-circuit semantics: " + orTri);
        check(andTri != null && andTri.startsWith("min(")
                        && andTri.contains("missing(b)") && andTri.contains(".5"),
                "AND tri-state translation lost nullable short-circuit semantics: " + andTri);
    }

    private static void testUtf8StringSizing() throws Exception {
        Class<?> colClass = Class.forName("org.worldbank.suso.Stata$Col");
        Constructor<?> constructor = colClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object col = constructor.newInstance();
        Method observe = colClass.getDeclaredMethod("observe", Object.class);
        observe.setAccessible(true);
        observe.invoke(col, "é🙂");
        Field maxLen = colClass.getDeclaredField("maxLen");
        maxLen.setAccessible(true);
        check(maxLen.getInt(col) == "é🙂".getBytes(StandardCharsets.UTF_8).length,
                "Stata string width is not UTF-8 byte-correct");
    }

    private static void testEncryptedZip(Path archive) throws Exception {
        Path base = Files.createTempDirectory("suso-encrypted-zip-test-");
        Path goodDir = base.resolve("good");
        Zip.Result good = Zip.extract(archive.toString(), goodDir.toString(), "secret");
        check(good.error == null && good.files == 1,
                "valid encrypted ZIP failed: " + good.error);
        check("encrypted-content\n".equals(Files.readString(goodDir.resolve("plain.txt"))),
                "encrypted ZIP content");

        Path badDir = base.resolve("bad");
        Files.createDirectories(badDir);
        Path target = badDir.resolve("plain.txt");
        Files.writeString(target, "sentinel");
        Zip.Result bad = Zip.extract(archive.toString(), badDir.toString(), "wrong");
        check(bad.error != null && bad.badPassword, "wrong ZIP password was accepted");
        check("sentinel".equals(Files.readString(target)),
                "wrong-password extraction replaced prior file");
    }

    private static void testZipContainmentAndAtomicity() throws Exception {
        Path base = Files.createTempDirectory("suso-zip-test-");
        Path safeZip = base.resolve("safe.zip");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(safeZip))) {
            out.putNextEntry(new ZipEntry("nested/ok.txt"));
            out.write("correct".getBytes(StandardCharsets.UTF_8));
            out.closeEntry();
        }
        Path destination = base.resolve("out");
        Zip.Result safe = Zip.extract(safeZip.toString(), destination.toString(), "");
        check(safe.error == null, "safe ZIP failed: " + safe.error);
        check(safe.files == 1, "safe ZIP count");
        check("correct".equals(Files.readString(destination.resolve("nested/ok.txt"))),
                "safe ZIP content");

        Path traversalZip = base.resolve("traversal.zip");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(traversalZip))) {
            out.putNextEntry(new ZipEntry("../../escaped.txt"));
            out.write("escaped".getBytes(StandardCharsets.UTF_8));
            out.closeEntry();
        }
        Zip.Result traversal = Zip.extract(traversalZip.toString(), destination.toString(), "");
        check(traversal.error != null, "traversal ZIP was accepted");
        check(!Files.exists(base.resolve("escaped.txt")), "traversal wrote outside destination");

        Path corruptZip = base.resolve("corrupt.zip");
        byte[] payload = "new-value".getBytes(StandardCharsets.UTF_8);
        CRC32 crc = new CRC32();
        crc.update(payload);
        ZipEntry stored = new ZipEntry("sentinel.txt");
        stored.setMethod(ZipEntry.STORED);
        stored.setSize(payload.length);
        stored.setCompressedSize(payload.length);
        stored.setCrc(crc.getValue());
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(corruptZip))) {
            out.putNextEntry(stored);
            out.write(payload);
            out.closeEntry();
        }
        byte[] zipBytes = Files.readAllBytes(corruptZip);
        int nameLength = (zipBytes[26] & 0xff) | ((zipBytes[27] & 0xff) << 8);
        int extraLength = (zipBytes[28] & 0xff) | ((zipBytes[29] & 0xff) << 8);
        int dataOffset = 30 + nameLength + extraLength;
        zipBytes[dataOffset] ^= 1;
        Files.write(corruptZip, zipBytes, StandardOpenOption.TRUNCATE_EXISTING);
        Path sentinel = destination.resolve("sentinel.txt");
        Files.writeString(sentinel, "old-value");
        Zip.Result corrupt = Zip.extract(corruptZip.toString(), destination.toString(), "");
        check(corrupt.error != null, "CRC-corrupt ZIP was accepted");
        check("old-value".equals(Files.readString(sentinel)),
                "failed extraction replaced an existing file");

        Path outside = base.resolve("outside.txt");
        Files.writeString(outside, "outside-old");
        Path link = destination.resolve("link.txt");
        try {
            Files.createSymbolicLink(link, outside);
        } catch (UnsupportedOperationException | IOException | SecurityException ignored) {
            // The other containment assertions still run where symlinks are unavailable.
            return;
        }
        Path linkZip = base.resolve("link.zip");
        try (ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(linkZip))) {
            out.putNextEntry(new ZipEntry("link.txt"));
            out.write("overwrite".getBytes(StandardCharsets.UTF_8));
            out.closeEntry();
        }
        Zip.Result symlink = Zip.extract(linkZip.toString(), destination.toString(), "");
        check(symlink.error != null && Path.of(symlink.dir).equals(destination),
                "symlink collision did not fail in the exact requested directory");
        check(Files.isSymbolicLink(link), "existing folder's symlink was changed");
        check("outside-old".equals(Files.readString(outside)), "symlink escaped destination");
    }

    private static void testHttpRedirectsAndDownloads() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/redirect307", exchange -> redirect(exchange, 307, "/echo"));
        server.createContext("/redirect303", exchange -> redirect(exchange, 303, "/echo"));
        server.createContext("/echo", exchange -> {
            byte[] body = exchange.getRequestBody().readAllBytes();
            respond(exchange, 200, exchange.getRequestMethod() + "|"
                    + new String(body, StandardCharsets.UTF_8));
        });
        server.createContext("/download", exchange -> respond(exchange, 200, "complete-file"));
        server.createContext("/broken", exchange -> {
            exchange.sendResponseHeaders(200, 100);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write("short".getBytes(StandardCharsets.UTF_8));
            }
        });
        server.start();
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            Http.Result keep = Http.request("PATCH", base + "/redirect307", "", "body",
                    "text/plain", "text/plain", 3000, 3000, "", 0, "", "", false, "");
            check(keep.status == 200 && "PATCH|body".equals(keep.body),
                    "307 did not preserve method/body: " + keep.status + " " + keep.body);
            Http.Result byteKeep = Http.requestBytes("POST", base + "/redirect307", "",
                    "multipart-body".getBytes(StandardCharsets.UTF_8), "text/plain", "text/plain",
                    3000, 3000, "", 0, "", "", false);
            check(byteKeep.status == 200 && "POST|multipart-body".equals(byteKeep.body),
                    "307 did not preserve multipart byte body");
            Http.Result change = Http.request("POST", base + "/redirect303", "", "body",
                    "text/plain", "text/plain", 3000, 3000, "", 0, "", "", false, "");
            check(change.status == 200 && "GET|".equals(change.body),
                    "303 did not convert to GET: " + change.status + " " + change.body);

            Path baseDir = Files.createTempDirectory("suso-http-test-");
            Path target = baseDir.resolve("download.bin");
            Files.writeString(target, "old-file");
            Http.Result ok = Http.request("GET", base + "/download", "", "", "", "",
                    3000, 3000, "", 0, "", "", false, target.toString());
            check(ok.status == 200 && ok.error == null, "successful download failed");
            check("complete-file".equals(Files.readString(target)), "download content");

            Files.writeString(target, "sentinel");
            Http.Result broken = Http.request("GET", base + "/broken", "", "", "", "",
                    3000, 3000, "", 0, "", "", false, target.toString());
            check(broken.error != null, "truncated download reported success");
            check("sentinel".equals(Files.readString(target)),
                    "truncated download destroyed prior file");

            String before = System.getProperty(
                    "jdk.internal.httpclient.disableHostnameVerification");
            Http.request("GET", base + "/echo", "", "", "", "",
                    3000, 3000, "", 0, "", "", true, "");
            String after = System.getProperty(
                    "jdk.internal.httpclient.disableHostnameVerification");
            check(java.util.Objects.equals(before, after),
                    "insecure request mutated JVM-global hostname verification");
        } finally {
            server.stop(0);
        }
    }

    private static void redirect(HttpExchange exchange, int status, String target)
            throws IOException {
        exchange.getResponseHeaders().add("Location", target);
        exchange.sendResponseHeaders(status, -1);
        exchange.close();
    }

    private static void respond(HttpExchange exchange, int status, String value)
            throws IOException {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) { out.write(bytes); }
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
