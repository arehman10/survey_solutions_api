package org.worldbank.suso;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal, dependency-free JSON parser and serializer.
 *
 * <p>Parsing produces a tree of: {@link LinkedHashMap}{@code <String,Object>} (objects, order
 * preserved), {@link ArrayList}{@code <Object>} (arrays), {@link String}, {@link Long}
 * (integral numbers that fit in a long), {@link Double} (everything else numeric),
 * {@link Boolean}, or {@code null}.</p>
 *
 * <p>This is intentionally self-contained so the shipped jar has zero third-party
 * dependencies, which matters on locked-down corporate (WBG) machines.</p>
 */
public final class Json {

    private final String s;
    private int i;

    private Json(String s) { this.s = s; this.i = 0; }

    /** Parse a JSON document. Returns {@code null} for {@code null}/empty input. */
    public static Object parse(String text) {
        if (text == null) return null;
        // tolerate a UTF-8 BOM
        if (text.length() > 0 && text.charAt(0) == '\uFEFF') text = text.substring(1);
        Json p = new Json(text);
        p.ws();
        if (p.i >= p.s.length()) return null;
        Object v = p.value();
        p.ws();
        if (p.i < p.s.length())
            throw p.err("Unexpected trailing characters");
        return v;
    }

    private Object value() {
        ws();
        if (i >= s.length()) throw err("Unexpected end of input");
        char c = s.charAt(i);
        switch (c) {
            case '{': return object();
            case '[': return array();
            case '"': return string();
            case 't':
            case 'f': return bool();
            case 'n': return nul();
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number();
                throw err("Unexpected character '" + c + "'");
        }
    }

    private Map<String, Object> object() {
        LinkedHashMap<String, Object> m = new LinkedHashMap<>();
        expect('{');
        ws();
        if (peek() == '}') { i++; return m; }
        while (true) {
            ws();
            if (peek() != '"') throw err("Expected string key");
            String k = string();
            ws();
            expect(':');
            m.put(k, value());
            ws();
            char c = next();
            if (c == '}') break;
            if (c != ',') throw err("Expected ',' or '}'");
        }
        return m;
    }

    private List<Object> array() {
        ArrayList<Object> a = new ArrayList<>();
        expect('[');
        ws();
        if (peek() == ']') { i++; return a; }
        while (true) {
            a.add(value());
            ws();
            char c = next();
            if (c == ']') break;
            if (c != ',') throw err("Expected ',' or ']'");
        }
        return a;
    }

    private String string() {
        expect('"');
        StringBuilder sb = new StringBuilder();
        while (true) {
            if (i >= s.length()) throw err("Unterminated string");
            char c = s.charAt(i++);
            if (c == '"') break;
            if (c == '\\') {
                if (i >= s.length()) throw err("Unterminated escape");
                char e = s.charAt(i++);
                switch (e) {
                    case '"':  sb.append('"');  break;
                    case '\\': sb.append('\\'); break;
                    case '/':  sb.append('/');  break;
                    case 'b':  sb.append('\b'); break;
                    case 'f':  sb.append('\f'); break;
                    case 'n':  sb.append('\n'); break;
                    case 'r':  sb.append('\r'); break;
                    case 't':  sb.append('\t'); break;
                    case 'u':
                        if (i + 4 > s.length()) throw err("Bad \\u escape");
                        sb.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                        i += 4;
                        break;
                    default: throw err("Bad escape \\" + e);
                }
            } else {
                sb.append(c);
            }
        }
        return sb.toString();
    }

    private Object number() {
        int start = i;
        if (peek() == '-') i++;
        while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        boolean fractional = false;
        if (i < s.length() && s.charAt(i) == '.') {
            fractional = true; i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        }
        if (i < s.length() && (s.charAt(i) == 'e' || s.charAt(i) == 'E')) {
            fractional = true; i++;
            if (i < s.length() && (s.charAt(i) == '+' || s.charAt(i) == '-')) i++;
            while (i < s.length() && Character.isDigit(s.charAt(i))) i++;
        }
        String num = s.substring(start, i);
        if (!fractional) {
            try { return Long.valueOf(Long.parseLong(num)); }
            catch (NumberFormatException ignore) { /* too big for long -> fall through */ }
        }
        return Double.valueOf(Double.parseDouble(num));
    }

    private Boolean bool() {
        if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
        if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
        throw err("Invalid literal");
    }

    private Object nul() {
        if (s.startsWith("null", i)) { i += 4; return null; }
        throw err("Invalid literal");
    }

    private void ws() {
        while (i < s.length()) {
            char c = s.charAt(i);
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++;
            else break;
        }
    }

    private char peek() { if (i >= s.length()) throw err("Unexpected end of input"); return s.charAt(i); }
    private char next() { if (i >= s.length()) throw err("Unexpected end of input"); return s.charAt(i++); }
    private void expect(char c) { if (i >= s.length() || s.charAt(i) != c) throw err("Expected '" + c + "'"); i++; }
    private RuntimeException err(String m) { return new RuntimeException("JSON parse error: " + m + " at position " + i); }

    // ----------------------------------------------------------------- writer

    /** Serialize an object tree to compact JSON. */
    public static String write(Object o) {
        StringBuilder sb = new StringBuilder();
        writeValue(sb, o);
        return sb.toString();
    }

    private static void writeValue(StringBuilder sb, Object o) {
        if (o == null) { sb.append("null"); return; }
        if (o instanceof String) { writeString(sb, (String) o); return; }
        if (o instanceof Boolean) { sb.append(((Boolean) o) ? "true" : "false"); return; }
        if (o instanceof Double) {
            double d = (Double) o;
            if (!Double.isInfinite(d) && !Double.isNaN(d) && d == Math.floor(d) && Math.abs(d) < 1e15)
                sb.append(Long.toString((long) d));
            else
                sb.append(Double.toString(d));
            return;
        }
        if (o instanceof Number) { sb.append(o.toString()); return; }
        if (o instanceof Map) {
            sb.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> e : ((Map<?, ?>) o).entrySet()) {
                if (!first) sb.append(',');
                first = false;
                writeString(sb, String.valueOf(e.getKey()));
                sb.append(':');
                writeValue(sb, e.getValue());
            }
            sb.append('}');
            return;
        }
        if (o instanceof Iterable) {
            sb.append('[');
            boolean first = true;
            for (Object e : (Iterable<?>) o) {
                if (!first) sb.append(',');
                first = false;
                writeValue(sb, e);
            }
            sb.append(']');
            return;
        }
        writeString(sb, String.valueOf(o));
    }

    private static void writeString(StringBuilder sb, String str) {
        sb.append('"');
        for (int k = 0; k < str.length(); k++) {
            char c = str.charAt(k);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
            }
        }
        sb.append('"');
    }
}
