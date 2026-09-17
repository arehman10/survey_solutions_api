package org.worldbank.suso;

import com.sun.net.httpserver.HttpServer;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.util.Arrays;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Runs against either release without linking its implementation at compile time.
 * Connection count is the useful comparison; loopback timing is not an Internet benchmark.
 */
public final class HttpReuseProbe {
    private HttpReuseProbe() { }

    public static void main(String[] args) throws Exception {
        int count = args.length == 0 ? 8 : Integer.parseInt(args[0]);
        if (count < 1 || count > 1000) throw new IllegalArgumentException("request count must be 1..1000");
        Class<?> bridge = Class.forName("org.worldbank.suso.Http");
        Method request = bridge.getMethod("request", String.class, String.class, String.class,
                String.class, String.class, String.class, int.class, int.class, String.class,
                int.class, String.class, String.class, boolean.class, String.class);
        byte[] body = new byte[4096];
        Arrays.fill(body, (byte) 'x');
        Set<Integer> ports = ConcurrentHashMap.newKeySet();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        ExecutorService executor = Executors.newCachedThreadPool();
        server.setExecutor(executor);
        server.createContext("/probe", exchange -> {
            ports.add(exchange.getRemoteAddress().getPort());
            try {
                exchange.getResponseHeaders().set("Content-Type", "text/plain");
                exchange.sendResponseHeaders(200, body.length);
                exchange.getResponseBody().write(body);
            } finally { exchange.close(); }
        });
        server.start();
        try {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/probe";
            long started = System.nanoTime();
            for (int i = 0; i < count; i++) {
                Object result = request.invoke(null, "GET", url, "", "", "", "text/plain",
                        1500, 3000, "", 0, "", "", false, "");
                int status = result.getClass().getField("status").getInt(result);
                Object error = result.getClass().getField("error").get(result);
                String received = String.valueOf(result.getClass().getField("body").get(result));
                if (status != 200 || error != null || received.length() != body.length) {
                    throw new AssertionError("request " + (i + 1) + " failed: status=" + status + ", error=" + error);
                }
            }
            long elapsed = (System.nanoTime() - started) / 1_000_000L;
            System.out.println("requests=" + count + " distinct_tcp_connections=" + ports.size()
                    + " elapsed_ms=" + elapsed + " response_bytes=" + body.length);
        } finally {
            server.stop(0);
            executor.shutdownNow();
        }
    }
}
