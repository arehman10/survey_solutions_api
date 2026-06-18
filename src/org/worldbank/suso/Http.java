package org.worldbank.suso;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.Authenticator;
import java.net.InetSocketAddress;
import java.net.PasswordAuthentication;
import java.net.ProxySelector;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Thin HTTP layer built on {@link java.net.http.HttpClient} (requires a Java 11+ runtime).
 *
 * <p>Features needed by the Survey Solutions REST API and the WBG corporate network:</p>
 * <ul>
 *   <li>All verbs incl. PATCH (used heavily by SuSo) and DELETE.</li>
 *   <li>Explicit proxy host/port (+ optional proxy credentials).</li>
 *   <li>Optional TLS-insecure mode (disables cert + hostname checks) as an escape hatch
 *       when the corporate MITM CA is not in the JVM trust store. Loud warning is the
 *       caller's job.</li>
 *   <li>Manual, bounded redirect following that <b>drops the Authorization header on a
 *       cross-origin redirect</b> (so credentials never leak to a pre-signed cloud URL).</li>
 *   <li>Streaming downloads to disk (no buffering the whole file in memory).</li>
 * </ul>
 *
 * <p>This class has no dependency on Stata's SFI, so it can be unit-tested standalone.</p>
 */
public final class Http {

    private static final int MAX_REDIRECTS = 5;

    /** Result of a request. {@code status==0} together with a non-null {@code error} means transport failure. */
    public static final class Result {
        public int status;
        public String body = "";
        public long bytes = 0;
        public String savedPath = null;
        public String finalUrl;
        public String contentType = "";
        public String error = null;
    }

    private Http() {}

    public static Result request(
            String method, String url, String authHeader,
            String body, String contentType, String accept,
            int connectTimeoutMs, int readTimeoutMs,
            String proxyHost, int proxyPort, String proxyUser, String proxyPass,
            boolean insecure, String saveFile) {

        Result r = new Result();
        r.finalUrl = url;
        try {
            if (insecure) {
                // Documented escape hatch for HttpClient hostname verification.
                System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
            }

            HttpClient.Builder cb = HttpClient.newBuilder()
                    .followRedirects(HttpClient.Redirect.NEVER) // we follow manually & safely
                    .connectTimeout(Duration.ofMillis(connectTimeoutMs <= 0 ? 30000 : connectTimeoutMs));

            if (proxyHost != null && !proxyHost.isEmpty() && proxyPort > 0) {
                cb.proxy(ProxySelector.of(new InetSocketAddress(proxyHost, proxyPort)));
                if (proxyUser != null && !proxyUser.isEmpty()) {
                    final String pu = proxyUser;
                    final char[] pp = (proxyPass == null ? "" : proxyPass).toCharArray();
                    cb.authenticator(new Authenticator() {
                        @Override protected PasswordAuthentication getPasswordAuthentication() {
                            if (getRequestorType() == RequestorType.PROXY)
                                return new PasswordAuthentication(pu, pp);
                            return null;
                        }
                    });
                }
            }
            if (insecure) cb.sslContext(trustAllContext());

            HttpClient client = cb.build();

            HttpRequest.Builder rb = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofMillis(readTimeoutMs <= 0 ? 300000 : readTimeoutMs));

            if (authHeader != null && !authHeader.isEmpty()) rb.header("Authorization", authHeader);
            rb.header("Accept", (accept == null || accept.isEmpty()) ? "application/json" : accept);
            rb.header("User-Agent", "suso-stata/1.0");

            HttpRequest.BodyPublisher pub;
            if (body != null && !body.isEmpty()) {
                pub = HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8);
                rb.header("Content-Type", (contentType == null || contentType.isEmpty()) ? "application/json" : contentType);
            } else {
                pub = HttpRequest.BodyPublishers.noBody();
            }
            rb.method(method.toUpperCase(Locale.ROOT), pub);

            HttpRequest req = rb.build();

            if (saveFile != null && !saveFile.isEmpty()) {
                return download(client, req, url, authHeader, saveFile);
            }

            return sendText(client, req, url, authHeader, r);

        } catch (Exception e) {
            r.status = 0;
            r.error = e.getClass().getSimpleName() + (e.getMessage() == null ? "" : (": " + e.getMessage()));
            return r;
        }
    }

    // -------------------------------------------------------------- text path

    /**
     * Like {@link #request} but sends a raw byte body with an explicit content type (used for
     * GraphQL multipart file uploads). Always returns the response as text.
     */
    public static Result requestBytes(
            String method, String url, String authHeader,
            byte[] body, String contentType, String accept,
            int connectTimeoutMs, int readTimeoutMs,
            String proxyHost, int proxyPort, String proxyUser, String proxyPass,
            boolean insecure) {

        Result r = new Result();
        r.finalUrl = url;
        try {
            if (insecure) System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");

            HttpClient.Builder cb = HttpClient.newBuilder()
                    .followRedirects(HttpClient.Redirect.NEVER)
                    .connectTimeout(Duration.ofMillis(connectTimeoutMs <= 0 ? 30000 : connectTimeoutMs));
            if (proxyHost != null && !proxyHost.isEmpty() && proxyPort > 0) {
                cb.proxy(ProxySelector.of(new InetSocketAddress(proxyHost, proxyPort)));
                if (proxyUser != null && !proxyUser.isEmpty()) {
                    final String pu = proxyUser;
                    final char[] pp = (proxyPass == null ? "" : proxyPass).toCharArray();
                    cb.authenticator(new Authenticator() {
                        @Override protected PasswordAuthentication getPasswordAuthentication() {
                            if (getRequestorType() == RequestorType.PROXY)
                                return new PasswordAuthentication(pu, pp);
                            return null;
                        }
                    });
                }
            }
            if (insecure) cb.sslContext(trustAllContext());
            HttpClient client = cb.build();

            HttpRequest.Builder rb = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .timeout(Duration.ofMillis(readTimeoutMs <= 0 ? 300000 : readTimeoutMs));
            if (authHeader != null && !authHeader.isEmpty()) rb.header("Authorization", authHeader);
            rb.header("Accept", (accept == null || accept.isEmpty()) ? "application/json" : accept);
            rb.header("User-Agent", "suso-stata/1.0");
            rb.header("GraphQL-Preflight", "1"); // satisfies servers that require a non-simple header for uploads
            rb.header("Content-Type", contentType);
            rb.method(method.toUpperCase(Locale.ROOT), HttpRequest.BodyPublishers.ofByteArray(body));

            return sendText(client, rb.build(), url, authHeader, r);
        } catch (Exception e) {
            r.status = 0;
            r.error = e.getClass().getSimpleName() + (e.getMessage() == null ? "" : (": " + e.getMessage()));
            return r;
        }
    }

    private static Result sendText(HttpClient client, HttpRequest req, String originUrl,
                                   String authHeader, Result r)
            throws Exception {
        final URI origin = URI.create(originUrl);
        HttpRequest current = req;
        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            HttpResponse<String> resp = client.send(current, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            int sc = resp.statusCode();
            if (sc >= 300 && sc < 400) {
                Optional<String> loc = resp.headers().firstValue("location");
                if (loc.isEmpty()) { fill(r, resp); return r; }
                if (hop == MAX_REDIRECTS) throw new java.io.IOException("Too many redirects");
                current = redirected(req, origin, current.uri().resolve(loc.get()), authHeader);
                continue;
            }
            fill(r, resp);
            return r;
        }
        return r;
    }

    private static void fill(Result r, HttpResponse<String> resp) {
        r.status = resp.statusCode();
        r.finalUrl = resp.uri().toString();
        r.body = resp.body() == null ? "" : resp.body();
        r.contentType = resp.headers().firstValue("content-type").orElse("");
        r.bytes = r.body.getBytes(StandardCharsets.UTF_8).length;
    }

    // ---------------------------------------------------------- download path

    private static Result download(HttpClient client, HttpRequest req, String originUrl,
                                   String authHeader, String saveFile)
            throws Exception {
        Result r = new Result();
        r.finalUrl = originUrl;
        final URI origin = URI.create(originUrl);
        // The export-file endpoint is a GET; req already carries the right URI/headers/timeout.
        HttpRequest current = req;

        for (int hop = 0; hop <= MAX_REDIRECTS; hop++) {
            HttpResponse<InputStream> resp = client.send(current, HttpResponse.BodyHandlers.ofInputStream());
            int sc = resp.statusCode();
            r.status = sc;
            r.finalUrl = resp.uri().toString();
            r.contentType = resp.headers().firstValue("content-type").orElse("");

            if (sc >= 300 && sc < 400) {
                Optional<String> loc = resp.headers().firstValue("location");
                try (InputStream is = resp.body()) { drain(is); }
                if (loc.isEmpty()) { r.error = "Redirect without Location header"; return r; }
                if (hop == MAX_REDIRECTS) throw new java.io.IOException("Too many redirects");
                current = redirected(req, origin, current.uri().resolve(loc.get()), authHeader);
                continue;
            }

            if (sc >= 200 && sc < 300) {
                Path out = Paths.get(saveFile);
                if (out.getParent() != null) Files.createDirectories(out.getParent());
                long count = 0;
                try (InputStream is = resp.body();
                     OutputStream os = Files.newOutputStream(out,
                             StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE)) {
                    byte[] buf = new byte[1 << 16];
                    int n;
                    while ((n = is.read(buf)) != -1) { os.write(buf, 0, n); count += n; }
                }
                r.savedPath = out.toAbsolutePath().toString();
                r.bytes = count;
                return r;
            }

            // error status: capture body text for a useful message
            try (InputStream is = resp.body()) {
                r.body = new String(is.readAllBytes(), StandardCharsets.UTF_8);
            }
            return r;
        }
        return r;
    }

    // --------------------------------------------------------------- helpers

    /** Build a redirected request, copying headers but dropping Authorization on cross-origin. */
    private static HttpRequest redirected(HttpRequest original, URI origin, URI next, String authHeader) {
        HttpRequest.Builder nb = HttpRequest.newBuilder()
                .uri(next)
                .timeout(original.timeout().orElse(Duration.ofMillis(300000)))
                .GET();
        for (Map.Entry<String, List<String>> e : original.headers().map().entrySet()) {
            String k = e.getKey();
            if (k.equalsIgnoreCase("Authorization")) continue;     // re-add conditionally below
            if (k.equalsIgnoreCase("Content-Length")) continue;
            if (k.equalsIgnoreCase("Host")) continue;
            for (String v : e.getValue()) {
                try { nb.header(k, v); } catch (IllegalArgumentException ignore) { /* restricted header */ }
            }
        }
        if (sameOrigin(origin, next) && authHeader != null && !authHeader.isEmpty()) {
            nb.header("Authorization", authHeader);
        }
        return nb.build();
    }

    private static boolean sameOrigin(URI a, URI b) {
        if (a == null || b == null) return false;
        String sa = nv(a.getScheme()).toLowerCase(Locale.ROOT);
        String sb = nv(b.getScheme()).toLowerCase(Locale.ROOT);
        String ha = nv(a.getHost()).toLowerCase(Locale.ROOT);
        String hb = nv(b.getHost()).toLowerCase(Locale.ROOT);
        int pa = a.getPort() == -1 ? defaultPort(sa) : a.getPort();
        int pb = b.getPort() == -1 ? defaultPort(sb) : b.getPort();
        return sa.equals(sb) && ha.equals(hb) && pa == pb;
    }

    private static int defaultPort(String scheme) { return "http".equals(scheme) ? 80 : 443; }
    private static String nv(String s) { return s == null ? "" : s; }

    private static void drain(InputStream is) throws Exception {
        byte[] buf = new byte[8192];
        while (is.read(buf) != -1) { /* discard */ }
    }

    private static SSLContext trustAllContext() throws Exception {
        TrustManager[] tm = new TrustManager[]{
                new X509TrustManager() {
                    public void checkClientTrusted(X509Certificate[] chain, String authType) {}
                    public void checkServerTrusted(X509Certificate[] chain, String authType) {}
                    public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
                }
        };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, tm, new SecureRandom());
        return ctx;
    }
}
