package org.worldbank.suso;

import com.stata.sfi.Data;
import com.stata.sfi.Macro;
import com.stata.sfi.SFIToolkit;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Bridge between Stata and the Survey Solutions REST API.
 *
 * <p>Entry point: {@code javacall org.worldbank.suso.Stata run , classpath("suso.jar")}.</p>
 *
 * <p>All input/output crosses the boundary through global macros named {@code SUSO_*}, which the
 * {@code suso.ado} program sets before the call and scrubs (especially the password) afterwards.
 * This avoids any ambiguity about macro scope during {@code javacall}.</p>
 *
 * <h3>Inputs (globals)</h3>
 * SUSO_BASE, SUSO_WS, SUSO_PATHBASE (path prefix, usually "/{ws}"; empty = server root),
 * SUSO_PATH, SUSO_METHOD, SUSO_QUERY, SUSO_BODY_REQ, SUSO_CTYPE, SUSO_ACCEPT,
 * SUSO_AUTHTYPE (basic|bearer), SUSO_USER, SUSO_PWD, SUSO_TOKEN,
 * SUSO_CONNTO, SUSO_READTO, SUSO_PROXYHOST, SUSO_PROXYPORT, SUSO_PROXYUSER, SUSO_PROXYPWD,
 * SUSO_INSECURE, SUSO_SAVEFILE, SUSO_TODATA, SUSO_ARRAYKEY, SUSO_VERBOSE,
 * SUSO_DESTRUCTIVE, SUSO_ALLOW_DESTRUCTIVE.
 *
 * <h3>Outputs (globals)</h3>
 * SUSO_RC ("0"=ok), SUSO_HTTP, SUSO_MSG, SUSO_BODY, SUSO_NOBS, SUSO_NVARS,
 * SUSO_TOTALCOUNT, SUSO_LIMIT, SUSO_OFFSET, SUSO_SAVED, SUSO_BYTES,
 * SUSO_DATECOLS (varnames to convert to %tc), SUSO_FKEYS + SUSO_F_&lt;key&gt; (flattened scalars).
 */
public final class Stata {

    private static final Pattern ISO_DT =
            Pattern.compile("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}.*$");
    private static final long INT_SAFE = 1L << 53;

    private Stata() {}

    /** Print the running JVM version so users can confirm Java >= 11. Returns 0 (rc) for javacall. */
    public static int jvm(String[] args) {
        String v = System.getProperty("java.version", "?");
        String vendor = System.getProperty("java.vendor", "?");
        String home = System.getProperty("java.home", "?");
        SFIToolkit.displayln("{txt}  Java version : {res}" + v);
        SFIToolkit.displayln("{txt}  Java vendor  : {res}" + vendor);
        SFIToolkit.displayln("{txt}  Java home    : {res}" + home);
        Macro.setGlobal("SUSO_JAVAVER", v);
        Macro.setGlobal("SUSO_JAVAOK", isJava11Plus() ? "1" : "0");
        if (!isJava11Plus()) {
            SFIToolkit.displayln("{err}  WARNING: this package needs Java 11 or newer. The PATCH-based");
            SFIToolkit.displayln("{err}           operations (approve/reject/assign/archive/...) require it.");
        }
        return 0;
    }

    /**
     * Prompt the user for credentials. Reads SUSO_PROMPT_USER (optional prefill) and writes
     * SUSO_USER / SUSO_PWD on success; sets SUSO_RC ("0" ok, "1" cancelled/unavailable) and
     * SUSO_MSG. Uses a masked Swing dialog in the GUI; falls back to the console in batch mode.
     */
    public static int prompt(String[] args) {
        try {
            String pre = g("SUSO_PROMPT_USER");
            boolean headless = java.awt.GraphicsEnvironment.isHeadless();
            if (!headless) {
                javax.swing.JTextField uf = new javax.swing.JTextField(pre, 22);
                javax.swing.JPasswordField pf = new javax.swing.JPasswordField(22);
                javax.swing.JPanel panel = new javax.swing.JPanel(new java.awt.GridLayout(0, 1, 4, 4));
                panel.add(new javax.swing.JLabel("Survey Solutions API user:"));
                panel.add(uf);
                panel.add(new javax.swing.JLabel("Password:"));
                panel.add(pf);
                // focus the empty field when shown
                pf.addAncestorListener(new javax.swing.event.AncestorListener() {
                    public void ancestorAdded(javax.swing.event.AncestorEvent e) {
                        (uf.getText().isEmpty() ? uf : pf).requestFocusInWindow();
                    }
                    public void ancestorMoved(javax.swing.event.AncestorEvent e) {}
                    public void ancestorRemoved(javax.swing.event.AncestorEvent e) {}
                });
                int ok = javax.swing.JOptionPane.showConfirmDialog(
                        null, panel, "suso \u2014 sign in",
                        javax.swing.JOptionPane.OK_CANCEL_OPTION,
                        javax.swing.JOptionPane.PLAIN_MESSAGE);
                if (ok != javax.swing.JOptionPane.OK_OPTION) {
                    setG("SUSO_RC", "1"); setG("SUSO_MSG", "sign-in cancelled"); return 0;
                }
                String u = uf.getText();
                String p = new String(pf.getPassword());
                if (u == null || u.trim().isEmpty()) {
                    setG("SUSO_RC", "1"); setG("SUSO_MSG", "no user name entered"); return 0;
                }
                setG("SUSO_USER", u.trim());
                setG("SUSO_PWD", p);
                setG("SUSO_RC", "0");
                return 0;
            }
            // headless: try the console (password is masked by the terminal)
            java.io.Console con = System.console();
            if (con != null) {
                String u = pre;
                if (u == null || u.isEmpty()) u = con.readLine("Survey Solutions API user: ");
                char[] p = con.readPassword("Password: ");
                if (u == null || u.trim().isEmpty()) {
                    setG("SUSO_RC", "1"); setG("SUSO_MSG", "no user name entered"); return 0;
                }
                setG("SUSO_USER", u.trim());
                setG("SUSO_PWD", p == null ? "" : new String(p));
                setG("SUSO_RC", "0");
                return 0;
            }
            setG("SUSO_RC", "1");
            setG("SUSO_MSG", "no interactive prompt available; set credentials with: suso config , user() password()");
        } catch (Throwable t) {
            setG("SUSO_RC", "1");
            setG("SUSO_MSG", "prompt failed: " + t.getClass().getSimpleName() + ": " + safe(t.getMessage()));
        }
        return 0;
    }

    /**
     * Extract a ZIP archive (including traditional ZipCrypto-encrypted exports). Reads
     * SUSO_ZIP_FILE, SUSO_ZIP_DIR (output folder) and SUSO_ZIP_PWD (optional password); writes
     * SUSO_RC, SUSO_MSG, SUSO_UNZIP_N (files written) and SUSO_UNZIP_DIR.
     */
    public static int unzip(String[] args) {
        try {
            String file = g("SUSO_ZIP_FILE");
            String dir  = g("SUSO_ZIP_DIR");
            String pwd  = g("SUSO_ZIP_PWD");
            setG("SUSO_UNZIP_N", "0"); setG("SUSO_UNZIP_DIR", "");
            if (file.isEmpty()) { setG("SUSO_RC", "198"); setG("SUSO_MSG", "no zip file specified"); return 0; }
            if (dir.isEmpty())  dir = new java.io.File(file).getParent();
            Zip.Result res = Zip.extract(file, dir, pwd);
            if (res.error != null) {
                setG("SUSO_RC", "679"); setG("SUSO_MSG", "unzip failed: " + res.error); return 0;
            }
            if (res.badPassword && res.files == 0) {
                setG("SUSO_RC", "459");
                setG("SUSO_MSG", "the archive is password-protected; supply the right password with unzipw(<pw>)");
                return 0;
            }
            setG("SUSO_UNZIP_N", Integer.toString(res.files));
            setG("SUSO_UNZIP_DIR", res.dir);
            StringBuilder m = new StringBuilder();
            if (res.badPassword) m.append("warning: wrong/empty password on some entries; ");
            if (res.skipped > 0) m.append(res.skipped).append(" entr").append(res.skipped == 1 ? "y" : "ies")
                                  .append(" skipped (unsupported encryption/method); ");
            setG("SUSO_MSG", m.toString());
            setG("SUSO_RC", "0");
        } catch (Throwable t) {
            setG("SUSO_RC", "679");
            setG("SUSO_MSG", "unzip failed: " + t.getClass().getSimpleName() + ": " + safe(t.getMessage()));
        }
        return 0;
    }

    /**
     * GraphQL bridge. Posts to {@code <base>/graphql}. Two modes:
     * <ul>
     *   <li>JSON query/mutation: set SUSO_GQL_BODY to the full {@code {"query":...,"variables":...}} JSON.</li>
     *   <li>Multipart file upload (uploadMap): set SUSO_UP_FILE (+ optional SUSO_UP_NAME), SUSO_GQL_OPERATIONS
     *       (the operations JSON) and optionally SUSO_GQL_MAP (defaults to {@code {"0":["variables.file"]}}).</li>
     * </ul>
     * If SUSO_GQL_TODATA=="1", the array at SUSO_GQL_NODEPATH (dotted, e.g. "maps.nodes") under {@code data}
     * is loaded as the dataset. GraphQL {@code errors} are surfaced via SUSO_RC/SUSO_MSG even on HTTP 200.
     */
    public static int gql(String[] args) {
        try {
            String base = stripTrailingSlash(g("SUSO_BASE"));
            if (base.isEmpty()) { fail(910, "No server configured. Run:  suso config , server(<url>)"); return 0; }
            String authType = lo(g("SUSO_AUTHTYPE"), "basic");
            String authHeader;
            if ("bearer".equals(authType)) {
                String token = g("SUSO_TOKEN");
                if (token.isEmpty()) { fail(910, "Bearer auth selected but no token is set."); return 0; }
                authHeader = "Bearer " + token;
            } else {
                String user = g("SUSO_USER"), pwd = g("SUSO_PWD");
                if (user.isEmpty()) { fail(910, "No credentials configured."); return 0; }
                authHeader = "Basic " + Base64.getEncoder().encodeToString((user + ":" + pwd).getBytes(StandardCharsets.UTF_8));
            }
            int connTo = pInt(g("SUSO_CONNTO"), 30000), readTo = pInt(g("SUSO_READTO"), 300000);
            String proxyHost = g("SUSO_PROXYHOST"); int proxyPort = pInt(g("SUSO_PROXYPORT"), 0);
            String proxyUser = g("SUSO_PROXYUSER"), proxyPwd = g("SUSO_PROXYPWD");
            boolean insecure = "1".equals(g("SUSO_INSECURE"));
            boolean verbose  = "1".equals(g("SUSO_VERBOSE"));
            String url = base + "/graphql";

            for (String k : new String[]{"SUSO_RC","SUSO_HTTP","SUSO_MSG","SUSO_BODY",
                    "SUSO_NOBS","SUSO_NVARS","SUSO_TOTALCOUNT","SUSO_FKEYS"}) setG(k, "");

            String upFile = g("SUSO_UP_FILE");
            Http.Result res;
            if (!upFile.isEmpty()) {
                String ops  = g("SUSO_GQL_OPERATIONS").replace("__DOLLAR__", "$");
                String mapj = g("SUSO_GQL_MAP"); if (mapj.isEmpty()) mapj = "{\"0\":[\"variables.file\"]}";
                java.io.File f = new java.io.File(upFile);
                String fname = g("SUSO_UP_NAME"); if (fname.isEmpty()) fname = f.getName();
                if (!f.exists()) { fail(601, "map file not found: " + upFile); return 0; }
                byte[] fileBytes = java.nio.file.Files.readAllBytes(f.toPath());
                String CRLF = "\r\n";
                String boundary = "----susoBoundary" + Long.toHexString(System.nanoTime());
                java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
                String pre = "--" + boundary + CRLF
                        + "Content-Disposition: form-data; name=\"operations\"" + CRLF + CRLF + ops + CRLF
                        + "--" + boundary + CRLF
                        + "Content-Disposition: form-data; name=\"map\"" + CRLF + CRLF + mapj + CRLF
                        + "--" + boundary + CRLF
                        + "Content-Disposition: form-data; name=\"0\"; filename=\"" + fname + "\"" + CRLF
                        + "Content-Type: application/zip" + CRLF + CRLF;
                bo.write(pre.getBytes(StandardCharsets.UTF_8));
                bo.write(fileBytes);
                bo.write((CRLF + "--" + boundary + "--" + CRLF).getBytes(StandardCharsets.UTF_8));
                if (verbose) SFIToolkit.displayln("{txt}[suso] POST " + url + "  (multipart upload "
                        + fileBytes.length + " bytes: " + fname + ")");
                res = Http.requestBytes("POST", url, authHeader, bo.toByteArray(),
                        "multipart/form-data; boundary=" + boundary, "application/json",
                        connTo, readTo, proxyHost, proxyPort, proxyUser, proxyPwd, insecure);
            } else {
                String body = g("SUSO_GQL_BODY").replace("__DOLLAR__", "$");
                if (verbose) {
                    SFIToolkit.displayln("{txt}[suso] POST " + url + "  (graphql)");
                    SFIToolkit.displayln("{txt}[suso] body: " + snippet(body, 1200));
                }
                res = Http.request("POST", url, authHeader, body, "application/json", "application/json",
                        connTo, readTo, proxyHost, proxyPort, proxyUser, proxyPwd, insecure, "");
            }

            if (res.error != null) { setG("SUSO_HTTP", "0"); fail(1, "Network/transport error: " + res.error); return 0; }
            int sc = res.status; setG("SUSO_HTTP", Integer.toString(sc));
            String rbody = res.body == null ? "" : res.body;
            setG("SUSO_BODY", snippet(rbody, 100000));

            Object root = null;
            try { root = Json.parse(rbody); } catch (Throwable ignore) {}
            if (root instanceof Map) {
                Object errs = ((Map<?, ?>) root).get("errors");
                if (errs instanceof List && !((List<?>) errs).isEmpty()) {
                    fail(sc >= 400 ? sc : 1, "GraphQL error: " + firstGqlError((List<?>) errs));
                    return 0;
                }
            }
            if (sc < 200 || sc >= 300) { fail(sc, friendly(sc, rbody)); return 0; }

            Object data = (root instanceof Map) ? ((Map<?, ?>) root).get("data") : null;
            if ("1".equals(g("SUSO_GQL_TODATA"))) {
                String nodePath = g("SUSO_GQL_NODEPATH");
                Object cur = data;
                if (cur instanceof Map && !nodePath.isEmpty()) {
                    for (String seg : nodePath.split("\\.")) if (cur instanceof Map) cur = ((Map<?, ?>) cur).get(seg);
                }
                // totalCount as a sibling of the nodes array
                if (data instanceof Map && nodePath.contains(".")) {
                    Object pc = data;
                    for (String seg : nodePath.substring(0, nodePath.lastIndexOf('.')).split("\\."))
                        if (pc instanceof Map) pc = ((Map<?, ?>) pc).get(seg);
                    if (pc instanceof Map) putInt("SUSO_TOTALCOUNT", ((Map<?, ?>) pc).get("totalCount"));
                }
                List<Object> arr = new ArrayList<>();
                if (cur instanceof List) { @SuppressWarnings("unchecked") List<Object> c = (List<Object>) cur; arr = c; }
                else if (cur != null) arr.add(cur);
                buildDataset(arr);
                setG("SUSO_RC", "0"); setG("SUSO_MSG", "OK");
                return 0;
            }
            try { if (data != null) flattenScalars(Json.write(data)); } catch (Throwable ignore) {}
            setG("SUSO_RC", "0"); setG("SUSO_MSG", "OK");
        } catch (Throwable t) {
            fail(1, "gql failed: " + t.getClass().getSimpleName() + ": " + safe(t.getMessage()));
        }
        return 0;
    }

    @SuppressWarnings("unchecked")
    private static String firstGqlError(List<?> errs) {
        Object e0 = errs.get(0);
        if (e0 instanceof Map) {
            Object m = ((Map<String, Object>) e0).get("message");
            if (m != null) return String.valueOf(m);
        }
        return String.valueOf(e0);
    }

    /**
     * Entry point invoked by {@code javacall}. The real outcome is conveyed to Stata through the
     * SUSO_* globals (notably SUSO_RC); the returned int is the javacall return code and is 0 unless
     * the bridge itself could not run.
     */
    public static int run(String[] args) {
        try {
            doRun();
        } catch (Throwable t) {
            setG("SUSO_RC", "1");
            if (g("SUSO_HTTP").isEmpty()) setG("SUSO_HTTP", "0");
            setG("SUSO_MSG", "Internal error: " + t.getClass().getSimpleName() + ": " + safe(t.getMessage()));
        }
        return 0;
    }

    private static void doRun() {
        // --- read inputs ---
        String base       = g("SUSO_BASE");
        String pathbase   = g("SUSO_PATHBASE");          // "" means server root
        String path       = g("SUSO_PATH");
        String method     = up(g("SUSO_METHOD"), "GET");
        String query      = g("SUSO_QUERY");
        String body       = g("SUSO_BODY_REQ");
        // The Stata layer encodes any '$' as __DOLLAR__ to avoid macro expansion of the
        // Survey Solutions "{guid}${version}" identity format. Translate it back here.
        if (query != null) query = query.replace("__DOLLAR__", "$");
        if (body != null) body = body.replace("__DOLLAR__", "$");
        String ctype      = g("SUSO_CTYPE");
        String accept     = g("SUSO_ACCEPT");
        String authType   = lo(g("SUSO_AUTHTYPE"), "basic");
        String user       = g("SUSO_USER");
        String pwd        = g("SUSO_PWD");
        String token      = g("SUSO_TOKEN");
        int connTo        = pInt(g("SUSO_CONNTO"), 30000);
        int readTo        = pInt(g("SUSO_READTO"), 300000);
        String proxyHost  = g("SUSO_PROXYHOST");
        int proxyPort     = pInt(g("SUSO_PROXYPORT"), 0);
        String proxyUser  = g("SUSO_PROXYUSER");
        String proxyPwd   = g("SUSO_PROXYPWD");
        boolean insecure  = "1".equals(g("SUSO_INSECURE"));
        String saveFile   = g("SUSO_SAVEFILE");
        boolean toData    = "1".equals(g("SUSO_TODATA"));
        String arrayKey   = g("SUSO_ARRAYKEY");
        boolean verbose   = "1".equals(g("SUSO_VERBOSE"));
        boolean destructive = "1".equals(g("SUSO_DESTRUCTIVE"));
        boolean allow       = "1".equals(g("SUSO_ALLOW_DESTRUCTIVE"));

        // Stata cannot safely carry a literal '$' (macro expansion). The .ado uses the token
        // __DOLLAR__ wherever a '$' is needed (e.g. questionnaire identity "guid$version").
        if (query != null) query = query.replace("__DOLLAR__", "$");
        if (body != null)  body  = body.replace("__DOLLAR__", "$");

        // --- reset outputs ---
        for (String k : new String[]{"SUSO_RC", "SUSO_HTTP", "SUSO_MSG", "SUSO_BODY",
                "SUSO_NOBS", "SUSO_NVARS", "SUSO_TOTALCOUNT", "SUSO_LIMIT", "SUSO_OFFSET",
                "SUSO_SAVED", "SUSO_BYTES", "SUSO_DATECOLS", "SUSO_FKEYS"}) setG(k, "");

        if (base == null || base.isEmpty()) {
            fail(910, "No server configured. Run:  suso config , server(<url>) workspace(<name>)");
            return;
        }

        // --- safety backstop: never run a destructive verb without the explicit flag ---
        if (destructive && !allow) {
            setG("SUSO_HTTP", "0");
            fail(909, "Destructive operation blocked by the Java safety backstop "
                    + "(SUSO_ALLOW_DESTRUCTIVE was not set). No request was sent.");
            return;
        }

        // --- auth header ---
        String authHeader;
        if ("bearer".equals(authType)) {
            if (token == null || token.isEmpty()) { fail(910, "Bearer auth selected but no token is set."); return; }
            authHeader = "Bearer " + token;
        } else {
            if (user == null || user.isEmpty()) {
                fail(910, "No credentials configured. Run:  suso config , user(<api user>) password(<pw>)");
                return;
            }
            String creds = user + ":" + (pwd == null ? "" : pwd);
            authHeader = "Basic " + Base64.getEncoder().encodeToString(creds.getBytes(StandardCharsets.UTF_8));
        }

        // --- URL ---
        String b = stripTrailingSlash(base);
        String prefix = (pathbase == null) ? "" : pathbase;
        if (!prefix.isEmpty() && !prefix.startsWith("/")) prefix = "/" + prefix;
        prefix = stripTrailingSlash(prefix);
        String p = (path == null) ? "" : path;
        if (!p.isEmpty() && !p.startsWith("/")) p = "/" + p;
        String url = b + prefix + p;
        if (query != null && !query.isEmpty()) url = url + (url.contains("?") ? "&" : "?") + query;

        if (verbose) {
            SFIToolkit.displayln("{txt}[suso] " + method + " " + url
                    + (insecure ? "  {err}(TLS verification DISABLED)" : ""));
        }

        // --- execute ---
        Http.Result res = Http.request(method, url, authHeader, body, ctype, accept,
                connTo, readTo, proxyHost, proxyPort, proxyUser, proxyPwd, insecure, saveFile);

        if (res.error != null) {
            setG("SUSO_HTTP", "0");
            fail(1, "Network/transport error: " + res.error
                    + (insecure ? "" : "  (TLS/proxy issue on the WBG network? See 'suso doctor' and the SSL notes in the README.)"));
            return;
        }

        int sc = res.status;
        setG("SUSO_HTTP", Integer.toString(sc));

        if (sc >= 200 && sc < 300) {
            if (saveFile != null && !saveFile.isEmpty()) {
                setG("SUSO_SAVED", res.savedPath == null ? "" : res.savedPath);
                setG("SUSO_BYTES", Long.toString(res.bytes));
                setG("SUSO_MSG", "Saved " + res.bytes + " bytes to " + res.savedPath);
                setG("SUSO_RC", "0");
                return;
            }
            if (toData) {
                try {
                    loadToData(res.body, arrayKey);
                    setG("SUSO_RC", "0");
                    setG("SUSO_MSG", "OK");
                } catch (Throwable t) {
                    setG("SUSO_BODY", snippet(res.body, 4000));
                    fail(2, "Response received but could not be parsed into a dataset: " + safe(t.getMessage()));
                }
                return;
            }
            setG("SUSO_BODY", snippet(res.body, 100000));
            try { flattenScalars(res.body); } catch (Throwable ignore) { /* best effort */ }
            setG("SUSO_RC", "0");
            setG("SUSO_MSG", "OK");
            return;
        }

        // --- error statuses ---
        setG("SUSO_BODY", snippet(res.body, 20000));
        fail(sc, friendly(sc, res.body));
    }

    // ----------------------------------------------------------- data loading

    private static void loadToData(String body, String preferredKey) {
        Object root = Json.parse(body);

        if (root instanceof Map) {
            Map<?, ?> m = (Map<?, ?>) root;
            putInt("SUSO_TOTALCOUNT", m.get("TotalCount"));
            putInt("SUSO_LIMIT", m.get("Limit"));
            putInt("SUSO_OFFSET", m.get("Offset"));
            if (m.containsKey("recordsTotal")) putInt("SUSO_TOTALCOUNT", m.get("recordsTotal"));
        }

        List<Object> arr = locateArray(root, preferredKey);
        buildDataset(arr);
    }

    @SuppressWarnings("unchecked")
    private static List<Object> locateArray(Object root, String preferredKey) {
        if (root instanceof List) return (List<Object>) root;
        if (root instanceof Map) {
            Map<String, Object> m = (Map<String, Object>) root;
            if (preferredKey != null && !preferredKey.isEmpty()
                    && m.get(preferredKey) instanceof List) {
                return (List<Object>) m.get(preferredKey);
            }
            String[] common = {"Interviews", "Assignments", "Users", "Questionnaires",
                    "History", "Records", "Answers", "data", "Data", "Items"};
            for (String k : common) {
                if (m.get(k) instanceof List) return (List<Object>) m.get(k);
            }
            for (Object v : m.values()) {
                if (v instanceof List) return (List<Object>) v;
            }
            // single object -> one-row dataset
            List<Object> one = new ArrayList<>();
            one.add(root);
            return one;
        }
        // scalar -> single cell
        List<Object> one = new ArrayList<>();
        one.add(root);
        return one;
    }

    private static void buildDataset(List<Object> arr) {
        int n = arr.size();
        if (n == 0) {
            setG("SUSO_NOBS", "0");
            setG("SUSO_NVARS", "0");
            return;
        }

        // 1) collect column order + per-column type info
        LinkedHashMap<String, Col> cols = new LinkedHashMap<>();
        for (Object o : arr) {
            if (o instanceof Map) {
                for (Map.Entry<?, ?> e : ((Map<?, ?>) o).entrySet()) {
                    String key = String.valueOf(e.getKey());
                    cols.computeIfAbsent(key, k -> new Col()).observe(e.getValue());
                }
            } else {
                cols.computeIfAbsent("value", k -> new Col()).observe(o);
            }
        }

        // 2) sanitize variable names (deduped)
        List<String> keys = new ArrayList<>(cols.keySet());
        Set<String> used = new HashSet<>();
        LinkedHashMap<String, String> varName = new LinkedHashMap<>();
        for (String key : keys) varName.put(key, uniqueName(sanitizeName(key, 32), used));

        // 3) create variables
        LinkedHashMap<String, Integer> idx = new LinkedHashMap<>();
        StringBuilder dateCols = new StringBuilder();
        for (String key : keys) {
            Col c = cols.get(key);
            String vn = varName.get(key);
            if (c.isString()) {
                int len = Math.max(1, c.maxLen);
                if (len > 2045) Data.addVarStrL(vn);
                else Data.addVarStr(vn, len);
            } else {
                Data.addVarDouble(vn);
            }
            int vi = Data.getVarIndex(vn);
            if (vi <= 0) throw new RuntimeException("Could not create variable '" + vn + "'");
            idx.put(key, vi);
            Data.setVarLabel(vi, key);
            if (c.isDate()) {
                if (dateCols.length() > 0) dateCols.append(" ");
                dateCols.append(vn);
            }
        }

        // 4) set observations and store values.
        //    New Stata cells default to missing (numeric) / "" (string), so null cells are
        //    simply left untouched -- this also avoids a dependency on Data.getMissingValue().
        Data.setObsTotal(n);
        for (int row = 0; row < n; row++) {
            long obs = row + 1;
            Object o = arr.get(row);
            if (o instanceof Map) {
                Map<?, ?> m = (Map<?, ?>) o;
                for (String key : keys) store(idx.get(key), obs, m.get(key), cols.get(key));
            } else {
                store(idx.get("value"), obs, o, cols.get("value"));
            }
        }

        setG("SUSO_NOBS", Integer.toString(n));
        setG("SUSO_NVARS", Integer.toString(keys.size()));
        setG("SUSO_DATECOLS", dateCols.toString());
    }

    private static void store(int vi, long obs, Object val, Col c) {
        if (val == null) return; // leave default (missing / "")
        if (c.isString()) {
            String s;
            if (val instanceof String) s = (String) val;
            else if (val instanceof Boolean) s = ((Boolean) val) ? "true" : "false";
            else if (val instanceof Map || val instanceof List) s = Json.write(val);
            else s = String.valueOf(val);
            if (!c.strL && c.maxLen > 0 && s.length() > c.maxLen) s = s.substring(0, c.maxLen);
            Data.storeStr(vi, obs, s);
        } else {
            double d;
            if (val instanceof Boolean) d = ((Boolean) val) ? 1.0 : 0.0;
            else if (val instanceof Number) d = ((Number) val).doubleValue();
            else return; // unexpected for a numeric column; leave missing
            Data.storeNum(vi, obs, d);
        }
    }

    /** Column type accumulator. */
    private static final class Col {
        boolean anyString, anyBool, anyNum, anyFrac, anyComplex, anyBigInt, anyNonNull, anyStringValue;
        boolean allDateLike = true;
        int maxLen = 0;
        boolean strL = false;

        void observe(Object v) {
            if (v == null) return;
            anyNonNull = true;
            if (v instanceof String) {
                anyString = true; anyStringValue = true;
                String s = (String) v;
                if (s.length() > maxLen) maxLen = s.length();
                if (!ISO_DT.matcher(s).matches()) allDateLike = false;
            } else if (v instanceof Boolean) {
                anyBool = true; allDateLike = false;
                if (maxLen < 5) maxLen = 5;
            } else if (v instanceof Long) {
                anyNum = true; allDateLike = false;
                long l = (Long) v;
                if (Math.abs(l) > INT_SAFE) anyBigInt = true;
                int len = Long.toString(l).length();
                if (len > maxLen) maxLen = len;
            } else if (v instanceof Double) {
                anyNum = true; anyFrac = true; allDateLike = false;
                int len = Double.toString((Double) v).length();
                if (len > maxLen) maxLen = len;
            } else {
                anyComplex = true; allDateLike = false;
                String s = Json.write(v);
                if (s.length() > maxLen) maxLen = s.length();
            }
            strL = maxLen > 2045;
        }

        /** Treat as a string column if it has text, complex values, or integers too big for exact doubles. */
        boolean isString() { return anyString || anyComplex || anyBigInt; }

        /** A pure ISO-datetime string column. */
        boolean isDate() {
            return anyStringValue && allDateLike && !anyComplex && !anyBool && !anyNum;
        }
    }

    // ------------------------------------------------------- scalar flattening

    private static void flattenScalars(String body) {
        Object root = Json.parse(body);
        if (!(root instanceof Map)) return;
        Map<?, ?> m = (Map<?, ?>) root;
        List<String> keys = new ArrayList<>();
        Set<String> used = new HashSet<>();
        for (Map.Entry<?, ?> e : m.entrySet()) {
            String key = String.valueOf(e.getKey());
            Object v = e.getValue();
            String sval;
            if (v == null) sval = "";
            else if (v instanceof String) sval = (String) v;
            else if (v instanceof Boolean) sval = ((Boolean) v) ? "1" : "0";
            else if (v instanceof Number) sval = numStr(v);
            else sval = Json.write(v);
            String k = uniqueName(sanitizeName(key, 28).toLowerCase(Locale.ROOT), used);
            setG("SUSO_F_" + k, snippet(sval, 8000));
            keys.add(k);
        }
        setG("SUSO_FKEYS", String.join(" ", keys));
    }

    // ----------------------------------------------------------- status text

    private static String friendly(int sc, String body) {
        String shortBody = snippet(stripJsonNoise(body), 400);
        switch (sc) {
            case 400: {
                String v = validationMessage(body);
                return "Bad request (400)." + (v.isEmpty() ? (shortBody.isEmpty() ? "" : " " + shortBody) : " " + v);
            }
            case 401:
                return "Unauthorized (401). Check the API user name/password, that the account has an API-capable "
                        + "role, and that it is assigned to this workspace.";
            case 403:
                return "Forbidden (403). The authenticated user lacks permission for this operation or workspace.";
            case 404:
                return "Not found (404). Check the id / name and the workspace.";
            case 406:
                return "Not acceptable (406). The target is in a state that does not allow this operation "
                        + "(e.g. the interview status, or the assignment cannot be changed).";
            case 409:
                return "Conflict (409)." + (shortBody.isEmpty() ? "" : " " + shortBody);
            case 429:
                return "Rate limited (429). Slow down and retry.";
            default:
                if (sc >= 500) return "Server error (" + sc + ")." + (shortBody.isEmpty() ? "" : " " + shortBody);
                return "HTTP " + sc + "." + (shortBody.isEmpty() ? "" : " " + shortBody);
        }
    }

    @SuppressWarnings("unchecked")
    private static String validationMessage(String body) {
        try {
            Object root = Json.parse(body);
            if (!(root instanceof Map)) return "";
            Map<String, Object> m = (Map<String, Object>) root;
            StringBuilder sb = new StringBuilder();
            Object errs = m.get("Errors");
            if (errs instanceof Map) {
                for (Map.Entry<?, ?> e : ((Map<?, ?>) errs).entrySet()) {
                    Object vals = e.getValue();
                    if (vals instanceof List) {
                        for (Object v : (List<?>) vals) appendMsg(sb, String.valueOf(v));
                    } else {
                        appendMsg(sb, String.valueOf(vals));
                    }
                }
            }
            if (sb.length() == 0) {
                if (m.get("Detail") != null) appendMsg(sb, String.valueOf(m.get("Detail")));
                else if (m.get("Title") != null) appendMsg(sb, String.valueOf(m.get("Title")));
            }
            return sb.toString();
        } catch (Throwable t) {
            return "";
        }
    }

    private static void appendMsg(StringBuilder sb, String s) {
        if (s == null || s.isEmpty() || "null".equals(s)) return;
        if (sb.length() > 0) sb.append("  ");
        sb.append(s);
    }

    // --------------------------------------------------------------- helpers

    private static String g(String name) {
        String v = Macro.getGlobal(name);
        return v == null ? "" : v;
    }

    private static void setG(String name, String value) {
        Macro.setGlobal(name, value == null ? "" : value);
    }

    private static void fail(int code, String msg) {
        setG("SUSO_RC", Integer.toString(code));
        setG("SUSO_MSG", msg);
    }

    private static void putInt(String name, Object v) {
        if (v instanceof Number) setG(name, Long.toString(((Number) v).longValue()));
    }

    private static String numStr(Object v) {
        if (v instanceof Long) return Long.toString((Long) v);
        if (v instanceof Double) {
            double d = (Double) v;
            if (d == Math.floor(d) && !Double.isInfinite(d) && Math.abs(d) < 1e15)
                return Long.toString((long) d);
            return Double.toString(d);
        }
        return String.valueOf(v);
    }

    private static String sanitizeName(String key, int maxLen) {
        if (key == null || key.isEmpty()) return "v";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < key.length() && sb.length() < maxLen; i++) {
            char c = key.charAt(i);
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')
                sb.append(c);
            else
                sb.append('_');
        }
        if (sb.length() == 0) return "v";
        char f = sb.charAt(0);
        if (!((f >= 'A' && f <= 'Z') || (f >= 'a' && f <= 'z') || f == '_')) sb.insert(0, '_');
        if (sb.length() > maxLen) sb.setLength(maxLen);
        return sb.toString();
    }

    private static String uniqueName(String base, Set<String> used) {
        String name = base;
        int k = 1;
        while (used.contains(name.toLowerCase(Locale.ROOT))) {
            String suffix = Integer.toString(++k);
            int cut = Math.min(base.length(), 32 - suffix.length());
            name = base.substring(0, Math.max(1, cut)) + suffix;
        }
        used.add(name.toLowerCase(Locale.ROOT));
        return name;
    }

    private static String snippet(String s, int max) {
        if (s == null) return "";
        if (s.length() <= max) return s;
        return s.substring(0, max) + " ...[truncated " + (s.length() - max) + " chars]";
    }

    private static String stripJsonNoise(String s) {
        if (s == null) return "";
        return s.replace("\r", " ").replace("\n", " ").trim();
    }

    private static String up(String s, String dflt) { return (s == null || s.isEmpty()) ? dflt : s.toUpperCase(Locale.ROOT); }
    private static String lo(String s, String dflt) { return (s == null || s.isEmpty()) ? dflt : s.toLowerCase(Locale.ROOT); }
    private static String safe(String s) { return s == null ? "" : s; }
    private static String stripTrailingSlash(String s) {
        if (s == null) return "";
        while (s.endsWith("/")) s = s.substring(0, s.length() - 1);
        return s;
    }

    private static int pInt(String s, int dflt) {
        if (s == null || s.isEmpty()) return dflt;
        try { return Integer.parseInt(s.trim()); } catch (NumberFormatException e) { return dflt; }
    }

    private static boolean isJava11Plus() {
        String v = System.getProperty("java.specification.version", "1.8");
        try {
            if (v.startsWith("1.")) return false;            // 1.8 etc.
            return Integer.parseInt(v.split("\\.")[0]) >= 11;
        } catch (Exception e) {
            return false;
        }
    }
}
