package org.worldbank.suso;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.net.Authenticator;
import java.net.InetSocketAddress;
import java.net.PasswordAuthentication;
import java.net.ProxySelector;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.security.SecureRandom;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.OptionalLong;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/** HTTP bridge used by the Stata entry point. */
public final class Http {
    private static final int MAX_REDIRECTS = 5;
    private static final int MAX_RETRIES = 2;
    private static final int MAX_CLIENTS = 8;
    // HttpClient owns its connection pool. Reusing a small number of immutable
    // clients avoids repeating TCP/TLS setup for export polling and downloads.
    // Authorization headers and authenticated proxy clients never enter this cache.
    private static final Map<ClientKey, HttpClient> CLIENTS =
            new LinkedHashMap<ClientKey, HttpClient>(16, 0.75f, true) {
                private static final long serialVersionUID = 1L;
                @Override protected boolean removeEldestEntry(Map.Entry<ClientKey, HttpClient> entry) {
                    return size() > MAX_CLIENTS;
                }
            };

    private Http() {}

    public static Result request(String method, String url, String authorization,
            String body, String contentType, String accept, int connectTimeout,
            int readTimeout, String proxyHost, int proxyPort, String proxyUser,
            String proxyPassword, boolean insecure, String savePath) {
        Result result = new Result();
        result.finalUrl = url;
        long started = System.nanoTime();
        try {
            URI uri = checkedUri(url, authorization);
            if (!empty(savePath) && insecure) throw new TransferException(
                    "Downloads require verified TLS; disable insecure mode and install the required trusted CA certificate");
            HttpClient client = client(connectTimeout, proxyHost, proxyPort,
                    proxyUser, proxyPassword, insecure);
            HttpRequest.BodyPublisher publisher;
            HttpRequest.Builder request = HttpRequest.newBuilder()
                    .uri(uri)
                    .timeout(Duration.ofMillis(readTimeout <= 0 ? 300000L : readTimeout));
            if (authorization != null && !authorization.isEmpty()) {
                request.header("Authorization", authorization);
            }
            request.header("Accept", empty(accept) ? "application/json" : accept);
            request.header("User-Agent", "suso-stata/1.7.32");
            if (!empty(body)) {
                publisher = HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8);
                request.header("Content-Type", empty(contentType)
                        ? "application/json" : contentType);
            } else {
                publisher = HttpRequest.BodyPublishers.noBody();
            }
            request.method(method.toUpperCase(Locale.ROOT), publisher);
            HttpRequest built = request.build();
            if (empty(savePath)) sendText(client, built, uri, authorization, result);
            else download(client, built, uri, authorization, savePath, result);
            return result;
        } catch (Exception ex) {
            result.status = 0;
            result.error = safeError(ex);
            return result;
        } finally {
            result.elapsedSeconds = (System.nanoTime() - started) / 1_000_000_000.0;
        }
    }

    public static Result requestBytes(String method, String url, String authorization,
            byte[] body, String contentType, String accept, int connectTimeout,
            int readTimeout, String proxyHost, int proxyPort, String proxyUser,
            String proxyPassword, boolean insecure) {
        Result result = new Result();
        result.finalUrl = url;
        long started = System.nanoTime();
        try {
            URI uri = checkedUri(url, authorization);
            HttpClient client = client(connectTimeout, proxyHost, proxyPort,
                    proxyUser, proxyPassword, insecure);
            HttpRequest.Builder request = HttpRequest.newBuilder()
                    .uri(uri)
                    .timeout(Duration.ofMillis(readTimeout <= 0 ? 300000L : readTimeout));
            if (!empty(authorization)) request.header("Authorization", authorization);
            request.header("Accept", empty(accept) ? "application/json" : accept);
            request.header("User-Agent", "suso-stata/1.7.32");
            request.header("GraphQL-Preflight", "1");
            request.header("Content-Type", contentType);
            request.method(method.toUpperCase(Locale.ROOT),
                    HttpRequest.BodyPublishers.ofByteArray(body));
            return sendText(client, request.build(), uri, authorization, result);
        } catch (Exception ex) {
            result.status = 0;
            result.error = safeError(ex);
            return result;
        } finally {
            result.elapsedSeconds = (System.nanoTime() - started) / 1_000_000_000.0;
        }
    }

    private static HttpClient client(int connectTimeout, String proxyHost,
            int proxyPort, String proxyUser, String proxyPassword,
            boolean insecure) throws Exception {
        long connectMillis = connectTimeout <= 0 ? 30000L : connectTimeout;
        boolean explicitProxy = !empty(proxyHost) && proxyPort > 0;
        ProxySelector selector = explicitProxy
                ? ProxySelector.of(new InetSocketAddress(proxyHost, proxyPort))
                : ProxySelector.getDefault();
        SSLContext defaultTls = SSLContext.getDefault();
        ClientKey key = new ClientKey(connectMillis, explicitProxy ? proxyHost : "",
                explicitProxy ? proxyPort : 0, insecure, defaultTls,
                explicitProxy ? null : selector);
        boolean cacheable = !explicitProxy || empty(proxyUser);
        synchronized (CLIENTS) {
            HttpClient cached = cacheable ? CLIENTS.get(key) : null;
            if (cached != null) return cached;
            HttpClient created = newClient(connectMillis, selector, explicitProxy,
                    proxyUser, proxyPassword, insecure, defaultTls);
            if (cacheable) CLIENTS.put(key, created);
            return created;
        }
    }

    private static HttpClient newClient(long connectMillis, ProxySelector selector,
            boolean explicitProxy, String proxyUser, String proxyPassword,
            boolean insecure, SSLContext defaultTls) throws Exception {
        HttpClient.Builder builder = HttpClient.newBuilder()
                .followRedirects(HttpClient.Redirect.NEVER)
                .connectTimeout(Duration.ofMillis(connectMillis));
        if (selector != null) builder.proxy(selector);
        if (explicitProxy) {
            if (!empty(proxyUser)) {
                final String user = proxyUser;
                final char[] password = (proxyPassword == null ? "" : proxyPassword).toCharArray();
                builder.authenticator(new Authenticator() {
                    @Override protected PasswordAuthentication getPasswordAuthentication() {
                        return getRequestorType() == RequestorType.PROXY
                                ? new PasswordAuthentication(user, password) : null;
                    }
                });
            }
        }
        if (insecure) {
            // Deliberately scoped to this client. Never mutate the JVM-global
            // jdk.internal.httpclient.disableHostnameVerification property.
            // Hostname verification remains active; only certificate-chain
            // validation is bypassed for this client.
            builder.sslContext(trustAllContext());
        } else builder.sslContext(defaultTls);
        return builder.build();
    }

    private static final class ClientKey {
        private final long timeout;
        private final String proxy;
        private final int port;
        private final boolean insecure;
        private final SSLContext tls;
        private final ProxySelector selector;
        ClientKey(long timeout, String proxy, int port, boolean insecure,
                SSLContext tls, ProxySelector selector) {
            this.timeout = timeout; this.proxy = proxy; this.port = port;
            this.insecure = insecure; this.tls = tls; this.selector = selector;
        }
        @Override public int hashCode() {
            return Objects.hash(timeout, proxy, port, insecure,
                    System.identityHashCode(tls), System.identityHashCode(selector));
        }
        @Override public boolean equals(Object other) {
            if (!(other instanceof ClientKey)) return false;
            ClientKey key = (ClientKey)other;
            return timeout == key.timeout && port == key.port && insecure == key.insecure
                    && proxy.equals(key.proxy) && tls == key.tls && selector == key.selector;
        }
    }

    private static Result sendText(HttpClient client, HttpRequest request,
            URI originalOrigin, String authorization, Result result) throws Exception {
        HttpRequest current = request;
        for (int redirects = 0; redirects <= MAX_REDIRECTS; redirects++) {
            HttpResponse<String> response = sendWithRetries(client, current,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8), result);
            int status = response.statusCode();
            if (status < 300 || status >= 400) {
                fill(result, response);
                return result;
            }
            Optional<String> location = response.headers().firstValue("location");
            if (location.isEmpty()) {
                fill(result, response);
                return result;
            }
            if (redirects == MAX_REDIRECTS) throw new IOException("Too many redirects");
            URI target = current.uri().resolve(location.get());
            current = redirected(current, originalOrigin, target, authorization, status);
        }
        return result;
    }

    /** Retry only explicitly transient responses to GET; never replay writes.
     * All attempts and backoff share this hop's original response deadline. */
    private static <T> HttpResponse<T> sendWithRetries(HttpClient client,
            HttpRequest request, HttpResponse.BodyHandler<T> handler, Result result) throws Exception {
        long deadline = System.nanoTime()
                + request.timeout().orElse(Duration.ofMillis(300000L)).toNanos();
        for (int retry = 0; ; retry++) {
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw new HttpTimeoutException("Request deadline exceeded");
            result.attempts++;
            HttpResponse<T> response = sendBounded(client, withTimeout(request, remaining), handler);
            if (!"GET".equals(request.method()) || retry >= MAX_RETRIES
                    || !retryable(response.statusCode())) return response;
            long delay = 200L * (retry + 1);
            Optional<String> retryAfter = response.headers().firstValue("retry-after");
            if (retryAfter.isPresent()) {
                try {
                    long seconds = Long.parseLong(retryAfter.get().trim());
                    // Do not ignore a server's long throttle instruction by
                    // retrying earlier, or hold an interactive Stata call indefinitely.
                    if (seconds < 0 || seconds > 2) return response;
                    delay = seconds * 1000L;
                } catch (NumberFormatException ex) {
                    // HTTP-date Retry-After: leave scheduling to the caller.
                    return response;
                }
            }
            if (deadline - System.nanoTime() <= TimeUnit.MILLISECONDS.toNanos(delay)) return response;
            Thread.sleep(delay);
        }
    }

    private static boolean retryable(int status) {
        return status == 429 || status == 502 || status == 503 || status == 504;
    }

    private static HttpRequest withTimeout(HttpRequest request, long nanos) {
        HttpRequest.Builder builder = HttpRequest.newBuilder(request.uri())
                .timeout(Duration.ofNanos(nanos))
                .expectContinue(request.expectContinue());
        request.version().ifPresent(builder::version);
        request.headers().map().forEach((name, values) ->
                values.forEach(value -> builder.header(name, value)));
        return builder.method(request.method(), request.bodyPublisher()
                .orElse(HttpRequest.BodyPublishers.noBody())).build();
    }

    private static void fill(Result result, HttpResponse<String> response) {
        result.status = response.statusCode();
        result.finalUrl = response.uri().toString();
        result.body = response.body() == null ? "" : response.body();
        result.contentType = response.headers().firstValue("content-type").orElse("");
        result.bytes = result.body.getBytes(StandardCharsets.UTF_8).length;
    }

    /**
     * The configured timeout covers headers AND complete body consumption for
     * each HTTP request (including each redirect hop). HttpRequest.timeout alone
     * does not reliably bound body subscribers on supported Java runtimes.
     */
    private static <T> HttpResponse<T> sendBounded(HttpClient client,
            HttpRequest request, HttpResponse.BodyHandler<T> bodyHandler) throws Exception {
        long timeoutNanos = request.timeout().orElse(Duration.ofMillis(300000L)).toNanos();
        long started = System.nanoTime();
        CancellableBodyHandler<T> handler = new CancellableBodyHandler<>(bodyHandler);
        CompletableFuture<HttpResponse<T>> pending = client.sendAsync(request, handler);
        try {
            long remaining = timeoutNanos - (System.nanoTime() - started);
            if (remaining <= 0) throw new TimeoutException();
            return pending.get(remaining, TimeUnit.NANOSECONDS);
        } catch (TimeoutException ex) {
            HttpTimeoutException timeout = new HttpTimeoutException(
                    "Request timed out while receiving headers or response body");
            handler.abort(timeout);
            pending.cancel(true);
            throw timeout;
        } catch (InterruptedException ex) {
            handler.abort(ex);
            pending.cancel(true);
            Thread.currentThread().interrupt();
            throw ex;
        } catch (ExecutionException ex) {
            Throwable cause = ex.getCause();
            if (cause instanceof Exception) throw (Exception)cause;
            throw new IOException("Response body failed", cause);
        }
    }

    /** Explicitly cancels the body subscription, including on Java 11. */
    private static final class CancellableBodyHandler<T> implements HttpResponse.BodyHandler<T> {
        private final HttpResponse.BodyHandler<T> delegate;
        private CancellableBodySubscriber<T> subscriber;
        private Throwable aborted;

        CancellableBodyHandler(HttpResponse.BodyHandler<T> delegate) { this.delegate = delegate; }

        @Override public synchronized HttpResponse.BodySubscriber<T> apply(HttpResponse.ResponseInfo info) {
            subscriber = new CancellableBodySubscriber<>(delegate.apply(info));
            if (aborted != null) subscriber.abort(aborted);
            return subscriber;
        }

        synchronized void abort(Throwable failure) {
            aborted = failure;
            if (subscriber != null) subscriber.abort(failure);
        }
    }

    private static final class CancellableBodySubscriber<T> implements HttpResponse.BodySubscriber<T> {
        private final HttpResponse.BodySubscriber<T> delegate;
        private Flow.Subscription subscription;
        private boolean finished;

        CancellableBodySubscriber(HttpResponse.BodySubscriber<T> delegate) { this.delegate = delegate; }
        @Override public CompletionStage<T> getBody() { return delegate.getBody(); }
        @Override public synchronized void onSubscribe(Flow.Subscription incoming) {
            if (finished || subscription != null) { incoming.cancel(); return; }
            subscription = incoming;
            delegate.onSubscribe(incoming);
        }
        @Override public synchronized void onNext(List<ByteBuffer> item) {
            if (!finished) delegate.onNext(item);
        }
        @Override public synchronized void onError(Throwable failure) {
            if (!finished) { finished = true; delegate.onError(failure); }
        }
        @Override public synchronized void onComplete() {
            if (!finished) { finished = true; delegate.onComplete(); }
        }
        synchronized void abort(Throwable failure) {
            if (finished) return;
            finished = true;
            if (subscription != null) subscription.cancel();
            // ofFile closes its channel here, so partial downloads can be deleted.
            delegate.onError(failure);
        }
    }

    private static Result download(HttpClient client, HttpRequest request,
            URI originalOrigin, String authorization, String savePath, Result result) throws Exception {
        result.finalUrl = originalOrigin.toString();
        Path target = Paths.get(savePath).toAbsolutePath().normalize();
        Path parent = target.getParent();
        if (parent == null) parent = Paths.get(".").toAbsolutePath().normalize();
        Files.createDirectories(parent);
        HttpRequest current = request;
        for (int redirects = 0; redirects <= MAX_REDIRECTS; redirects++) {
            // A file subscriber lets the timeout cover the complete streamed body.
            // Only a successful, fully received response replaces the destination.
            Path temp = Files.createTempFile(parent, ".suso-download-", ".part");
            boolean committed = false;
            try {
                DigestBodyHandler handler = new DigestBodyHandler(temp);
                HttpResponse<Path> response = sendWithRetries(client, current, handler, result);
                int status = response.statusCode();
                result.status = status;
                result.finalUrl = response.uri().toString();
                result.contentType = response.headers().firstValue("content-type").orElse("");
                if (status >= 300 && status < 400) {
                    Optional<String> location = response.headers().firstValue("location");
                    if (location.isEmpty()) {
                        result.error = "Redirect without Location header";
                        return result;
                    }
                    if (redirects == MAX_REDIRECTS) throw new IOException("Too many redirects");
                    URI redirectTarget = current.uri().resolve(location.get());
                    current = redirected(current, originalOrigin, redirectTarget, authorization, status);
                    continue;
                }
                if (status < 200 || status >= 300) {
                    // Error pages can be large or binary. The HTTP status is
                    // sufficient and cannot leak a token echoed by a server.
                    result.body = "Download failed with HTTP " + status;
                    return result;
                }
                if (status != 200) throw new TransferException(
                        "Expected a complete HTTP 200 download; received HTTP " + status);
                long bytes = Files.size(temp);
                if (bytes == 0) throw new TransferException("Empty download rejected");
                OptionalLong expected = response.headers().firstValueAsLong("content-length");
                if (expected.isPresent() && expected.getAsLong() != bytes) {
                    throw new TransferException("Incomplete download: expected "
                            + expected.getAsLong() + " bytes, received " + bytes);
                }
                if (current.headers().firstValue("accept").orElse("")
                        .toLowerCase(Locale.ROOT).contains("application/zip")
                        || result.contentType.toLowerCase(Locale.ROOT).contains("application/zip")) validateZip(temp);
                String sha256 = handler.hexDigest();
                try { result.backupPath = TransferFiles.publish(temp, target); }
                catch (IOException ex) {
                    // The local publisher's own errors contain filesystem
                    // recovery instructions, never remote URLs or credentials.
                    throw new TransferException("Could not place download: " + ex.getMessage());
                }
                committed = true;
                result.savedPath = target.toString();
                result.bytes = bytes;
                result.sha256 = sha256;
                return result;
            } finally {
                if (!committed) Files.deleteIfExists(temp);
            }
        }
        return result;
    }

    private static HttpRequest redirected(HttpRequest current, URI originalOrigin,
            URI target, String authorization, int status) throws IOException {
        checkedUri(target.toString(), sameOrigin(originalOrigin, target) ? authorization : "");
        if ("https".equalsIgnoreCase(current.uri().getScheme())
                && !"https".equalsIgnoreCase(target.getScheme())) {
            throw new TransferException("HTTPS redirect downgrade rejected");
        }
        boolean switchToGet = status == 303 && !"HEAD".equalsIgnoreCase(current.method());
        if (!switchToGet && !sameOrigin(current.uri(), target)
                && (!("GET".equals(current.method()) || "HEAD".equals(current.method()))
                    || current.bodyPublisher().map(HttpRequest.BodyPublisher::contentLength).orElse(0L) != 0)) {
            throw new TransferException("Cross-origin redirect of a write request or request body rejected");
        }
        HttpRequest.Builder builder = HttpRequest.newBuilder()
                .uri(target)
                .timeout(current.timeout().orElse(Duration.ofMillis(300000L)));
        for (Map.Entry<String, List<String>> entry : current.headers().map().entrySet()) {
            String name = entry.getKey();
            if (name.equalsIgnoreCase("Authorization")
                    || name.equalsIgnoreCase("Content-Length")
                    || name.equalsIgnoreCase("Host")
                    || (switchToGet && name.equalsIgnoreCase("Content-Type"))) continue;
            for (String value : entry.getValue()) {
                try { builder.header(name, value); }
                catch (IllegalArgumentException ignored) { }
            }
        }
        if (sameOrigin(originalOrigin, target) && !empty(authorization)) {
            builder.header("Authorization", authorization);
        }
        if (switchToGet) builder.GET();
        else builder.method(current.method(), current.bodyPublisher()
                .orElse(HttpRequest.BodyPublishers.noBody()));
        return builder.build();
    }

    private static boolean sameOrigin(URI a, URI b) {
        if (a == null || b == null) return false;
        String as = nv(a.getScheme()).toLowerCase(Locale.ROOT);
        String bs = nv(b.getScheme()).toLowerCase(Locale.ROOT);
        String ah = nv(a.getHost()).toLowerCase(Locale.ROOT);
        String bh = nv(b.getHost()).toLowerCase(Locale.ROOT);
        int ap = a.getPort() == -1 ? defaultPort(as) : a.getPort();
        int bp = b.getPort() == -1 ? defaultPort(bs) : b.getPort();
        return as.equals(bs) && ah.equals(bh) && ap == bp;
    }

    private static URI checkedUri(String url, String authorization) throws IOException {
        final URI uri;
        try { uri = URI.create(url); }
        catch (IllegalArgumentException ex) { throw new TransferException("Invalid request URL"); }
        if (uri.getUserInfo() != null) throw new TransferException(
                "Credentials in URLs are not supported; use the authorization configuration");
        if (empty(uri.getHost())) throw new TransferException("Request URL must include a valid host");
        if ("https".equalsIgnoreCase(uri.getScheme())) return uri;
        String host = uri.getHost();
        boolean loopback = "127.0.0.1".equals(host) || "::1".equals(host) || "[::1]".equals(host);
        if ("http".equalsIgnoreCase(uri.getScheme()) && loopback && empty(authorization)) return uri;
        throw new TransferException("HTTPS is required; only unauthenticated literal loopback HTTP is allowed");
    }

    private static String safeError(Exception ex) {
        // Never echo URL/query/header values from JDK exception messages. Signed
        // download URLs and credentials can otherwise appear in a Stata log.
        String message = ex instanceof TransferException ? ex.getMessage()
                : ex instanceof HttpTimeoutException ? "Request timed out while receiving headers or response body"
                : ex instanceof javax.net.ssl.SSLHandshakeException ? "TLS handshake failed; check the server certificate and trusted CA configuration"
                : ex instanceof InterruptedException ? "Request interrupted"
                : "Request or local file transfer failed; any prior destination was preserved";
        return ex.getClass().getSimpleName() + ": " + message;
    }

    private static final class TransferException extends IOException {
        private static final long serialVersionUID = 1L;
        TransferException(String message) { super(message); }
    }

    /** Hash the received bytes while ofFile writes them; no extra full-file read.
     * Each retry creates a fresh digest together with a truncated temporary file. */
    private static final class DigestBodyHandler implements HttpResponse.BodyHandler<Path> {
        private final Path file;
        private MessageDigest digest;
        DigestBodyHandler(Path file) { this.file = file; }
        @Override public HttpResponse.BodySubscriber<Path> apply(HttpResponse.ResponseInfo info) {
            try { digest = MessageDigest.getInstance("SHA-256"); }
            catch (java.security.NoSuchAlgorithmException ex) { throw new IllegalStateException(ex); }
            HttpResponse.BodySubscriber<Path> delegate = HttpResponse.BodyHandlers.ofFile(file,
                    StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE).apply(info);
            return new HttpResponse.BodySubscriber<Path>() {
                @Override public CompletionStage<Path> getBody() { return delegate.getBody(); }
                @Override public void onSubscribe(Flow.Subscription subscription) { delegate.onSubscribe(subscription); }
                @Override public void onNext(List<ByteBuffer> buffers) {
                    for (ByteBuffer buffer : buffers) digest.update(buffer.asReadOnlyBuffer());
                    delegate.onNext(buffers);
                }
                @Override public void onError(Throwable ex) { delegate.onError(ex); }
                @Override public void onComplete() { delegate.onComplete(); }
            };
        }
        String hexDigest() {
            StringBuilder hex = new StringBuilder(64);
            for (byte value : digest.digest()) hex.append(String.format(Locale.ROOT, "%02x", value & 255));
            return hex.toString();
        }
    }

    /** Check ZIP structure without inflating the archive twice or requiring its
     * password. The extraction stage validates every payload's CRC and size. */
    private static void validateZip(Path file) throws IOException {
        try (RandomAccessFile in = new RandomAccessFile(file.toFile(), "r")) {
            long length = in.length();
            if (length < 22) throw new TransferException("Downloaded ZIP is too short");
            long signature = u32(in);
            if (signature != 0x04034b50L && signature != 0x06054b50L && signature != 0x06064b50L)
                throw new TransferException("Downloaded response is not a ZIP archive");
            long eocd = -1;
            long tailStart = Math.max(0, length - 65557L);
            byte[] tail = new byte[(int)(length - tailStart)];
            in.seek(tailStart);
            in.readFully(tail);
            for (int offset = tail.length - 22; offset >= 0; offset--) {
                if ((tail[offset] & 255) == 0x50 && (tail[offset + 1] & 255) == 0x4b
                        && (tail[offset + 2] & 255) == 0x05 && (tail[offset + 3] & 255) == 0x06) {
                    int comment = (tail[offset + 20] & 255) | ((tail[offset + 21] & 255) << 8);
                    if (offset + 22 + comment == tail.length) { eocd = tailStart + offset; break; }
                }
            }
            if (eocd < 0) throw new TransferException("Downloaded ZIP is incomplete or invalid");
            in.seek(eocd + 4);
            int disk = u16(in), centralDisk = u16(in), diskCount = u16(in), entries16 = u16(in);
            long centralSize = u32(in), centralOffset = u32(in), entries = entries16;
            if (disk != 0 || centralDisk != 0 || diskCount != entries16)
                throw new TransferException("Multi-volume ZIP downloads are not supported");
            long centralLimit = eocd;
            if (entries == 65535 || centralSize == 0xffffffffL || centralOffset == 0xffffffffL) {
                if (eocd < 20) throw new TransferException("Invalid ZIP64 locator");
                in.seek(eocd - 20);
                if (u32(in) != 0x07064b50L || u32(in) != 0) throw new TransferException("Invalid ZIP64 locator");
                long zip64 = u64(in);
                if (u32(in) != 1 || zip64 < 0 || zip64 > eocd - 76)
                    throw new TransferException("Invalid ZIP64 end record");
                in.seek(zip64);
                if (u32(in) != 0x06064b50L) throw new TransferException("Invalid ZIP64 end signature");
                long recordSize = u64(in);
                if (recordSize < 44 || recordSize > eocd - 32 - zip64)
                    throw new TransferException("Truncated ZIP64 end record");
                in.seek(zip64 + 16);
                if (u32(in) != 0 || u32(in) != 0) throw new TransferException("Multi-volume ZIP64 is unsupported");
                long perDisk = u64(in);
                entries = u64(in); centralSize = u64(in); centralOffset = u64(in);
                if (entries != perDisk) throw new TransferException("Invalid ZIP64 entry count");
                centralLimit = zip64;
            }
            if (entries < 0 || entries > 1_000_000L || centralOffset < 0 || centralSize < 0
                    || centralOffset > centralLimit || centralSize != centralLimit - centralOffset)
                throw new TransferException("Invalid ZIP central directory bounds");
            long end = centralOffset + centralSize, position = centralOffset;
            for (long index = 0; index < entries; index++) {
                if (position > end - 46) throw new TransferException("Truncated ZIP central directory");
                in.seek(position);
                if (u32(in) != 0x02014b50L) throw new TransferException("Invalid ZIP central directory entry");
                in.seek(position + 20);
                long compressed = u32(in), uncompressed = u32(in);
                int nameLength = u16(in), extraLength = u16(in), commentLength = u16(in);
                if (u16(in) != 0) throw new TransferException("Multi-volume ZIP entry is unsupported");
                in.seek(position + 42);
                long localOffset = u32(in);
                long next = position + 46L + nameLength + extraLength + commentLength;
                if (next > end) throw new TransferException("Truncated ZIP directory entry fields");
                if (compressed == 0xffffffffL || uncompressed == 0xffffffffL || localOffset == 0xffffffffL) {
                    long extra = position + 46L + nameLength, extraEnd = extra + extraLength;
                    boolean found = false;
                    while (extra <= extraEnd - 4) {
                        in.seek(extra);
                        int tag = u16(in), size = u16(in);
                        long valueEnd = extra + 4L + size;
                        if (valueEnd > extraEnd) throw new TransferException("Invalid ZIP64 extra field");
                        if (tag == 1) {
                            int required = (uncompressed == 0xffffffffL ? 8 : 0)
                                    + (compressed == 0xffffffffL ? 8 : 0) + (localOffset == 0xffffffffL ? 8 : 0);
                            if (size < required) throw new TransferException("Incomplete ZIP64 entry sizes");
                            if (uncompressed == 0xffffffffL) uncompressed = u64(in);
                            if (compressed == 0xffffffffL) compressed = u64(in);
                            if (localOffset == 0xffffffffL) localOffset = u64(in);
                            found = true; break;
                        }
                        extra = valueEnd;
                    }
                    if (!found) throw new TransferException("Missing ZIP64 entry sizes");
                }
                if (localOffset < 0 || localOffset > centralOffset - 30 || compressed < 0 || uncompressed < 0)
                    throw new TransferException("Invalid ZIP entry bounds");
                in.seek(localOffset);
                if (u32(in) != 0x04034b50L) throw new TransferException("Invalid ZIP local file header");
                in.seek(localOffset + 26);
                long dataOffset = localOffset + 30L + u16(in) + u16(in);
                if (dataOffset > centralOffset || compressed > centralOffset - dataOffset)
                    throw new TransferException("Truncated ZIP entry payload");
                position = next;
            }
            if (position != end) throw new TransferException("ZIP central directory size mismatch");
        }
    }

    private static int u16(RandomAccessFile in) throws IOException {
        return in.readUnsignedByte() | in.readUnsignedByte() << 8;
    }
    private static long u32(RandomAccessFile in) throws IOException {
        return (long)u16(in) | (long)u16(in) << 16;
    }
    private static long u64(RandomAccessFile in) throws IOException {
        return u32(in) | u32(in) << 32;
    }

    private static int defaultPort(String scheme) {
        return "http".equals(scheme) ? 80 : 443;
    }

    private static String nv(String value) { return value == null ? "" : value; }
    private static boolean empty(String value) { return value == null || value.isEmpty(); }

    private static SSLContext trustAllContext() throws Exception {
        TrustManager[] managers = new TrustManager[]{new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] chain, String authType) { }
            @Override public void checkServerTrusted(X509Certificate[] chain, String authType) { }
            @Override public X509Certificate[] getAcceptedIssuers() {
                return new X509Certificate[0];
            }
        }};
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(null, managers, new SecureRandom());
        return context;
    }

    public static final class Result {
        public int status;
        public String body = "";
        public long bytes = 0L;
        public String savedPath;
        public String finalUrl;
        public String contentType = "";
        public String error;
        public String sha256 = "";
        public String backupPath = "";
        public double elapsedSeconds;
        public int attempts;
    }
}
