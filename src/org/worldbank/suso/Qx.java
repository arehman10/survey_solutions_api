/*
 * Recovered from the shipped SuSo backend (CFR 0.152), then restored to compilable source.
 * The questionnaire expression grammar is retained for compatibility.
 */
package org.worldbank.suso;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class Qx {
    static final char PAIR_SEP = '\u001d';
    static final char KV_SEP = '\u001e';
    static final String[] HEADER = new String[]{"qx_var", "qx_section", "qx_subsection", "qx_type", "qx_text", "qx_section_enable", "qx_group_enable", "qx_item_enable", "qx_parent_enable", "qx_enable", "qx_enable_deps", "qx_calc", "qx_nval", "qx_valmsg", "qx_opts", "qx_optvals", "qx_optmap", "qx_nopts", "qx_section_tri", "qx_group_tri", "qx_item_tri"};
    private static final Pattern QUESTION_START = Pattern.compile("<div\\s+class=\\\"question-container\\\"[^>]*>", 2);
    private static final Pattern DIV_TOKEN = Pattern.compile("<div\\b[^>]*>|</div>", 2);
    private static final Pattern VAR = Pattern.compile("class=\\\"variable_name\\\">\\s*(.*?)\\s*</div>", 34);
    private static final Pattern TITLE = Pattern.compile("class=\\\"question-title\\\"[^>]*>(.*?)</div>", 34);
    private static final Pattern TYPE = Pattern.compile("class=\\\"type\\\">\\s*(.*?)\\s*</div>", 34);
    private static final Pattern CONDITION = Pattern.compile("class=\\\"condition\\\">\\s*<span>E</span>(.*?)</div>", 34);
    private static final Pattern CALC = Pattern.compile("class=\\\"variable-expression\\\">(.*?)</div>", 34);
    private static final Pattern VALIDATION = Pattern.compile("class=\\\"validation-expression\\\"", 2);
    private static final Pattern VALIDATION_MSG = Pattern.compile("class=\\\"validation-message\\\"><span>M[0-9]+</span>(.*?)</div>", 34);
    private static final Pattern OPTION = Pattern.compile("class=\\\"option-value\\\"><span\\s*>(.*?)</span>.*?<label[^>]*>(.*?)</label>", 34);
    private static final Pattern SECTION_NAME = Pattern.compile("<h2[^>]*>(.*?)</h2>", 34);
    private static final Pattern GROUP_NAME = Pattern.compile("class=\\\"sub_section\\\"[^>]*>(.*?)</div>", 34);
    private static final Pattern APPENDIX = Pattern.compile("<span\\s+class=\\\"number\\\">\\[([0-9]+)]</span>\\s*<div\\s+class=\\\"appendix_detail\\\">(.*?)</div>", 34);
    private static final Pattern HTML_TAG = Pattern.compile("<[^>]*>", 32);
    private static final Pattern ENTITY_NUM = Pattern.compile("&#(x[0-9A-Fa-f]+|[0-9]+);");
    private static final Pattern COMMENT = Pattern.compile("//[^\\n\\r]*");
    private static final Pattern IDENT = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");
    private static final Pattern QUOTED = Pattern.compile("\\\"(?:\\\\.|[^\\\"])*\\\"");

    private Qx() {
    }

    static List<Map<String, String>> parse(Path path) throws IOException {
        String string;
        String string2 = Files.readString(path, StandardCharsets.UTF_8).replace("\r", "");
        Map<String, String> map = Qx.parseAppendix(string2);
        ArrayList<int[]> arrayList = new ArrayList<>();
        Matcher matcher = QUESTION_START.matcher(string2);
        while (matcher.find()) {
            arrayList.add(new int[]{matcher.start(), matcher.end()});
        }
        ArrayList<Map<String, String>> arrayList2 = new ArrayList<>();
        for (int i = 0; i < arrayList.size(); ++i) {
            String string3;
            int n = arrayList.get(i)[0];
            int n2 = arrayList.get(i)[1];
            int n3 = Qx.matchingDivEnd(string2, n2);
            if (n3 <= n2) {
                n3 = i + 1 < arrayList.size() ? arrayList.get(i + 1)[0] : string2.length();
            }
            if ((string3 = Qx.firstClean(VAR, string = string2.substring(n, Math.min(n3, string2.length())))).isEmpty()) continue;
            int n5 = string2.lastIndexOf("<section class=\"section\"", n);
            int n6 = string2.lastIndexOf("<div class=\"section_header\"", n);
            String string4 = Qx.boundedHeader(string2, n6, n);
            String string5 = Qx.firstClean(SECTION_NAME, string4);
            String string6 = Qx.resolve(Qx.firstClean(CONDITION, string4), map);
            int n7 = string2.lastIndexOf("<div class=\"group\">", n);
            int n8 = string2.lastIndexOf("<div class=\"group_footer\">", n);
            boolean bl = n7 >= 0 && n7 > n8 && n7 > n5;
            String string7 = bl ? Qx.boundedHeader(string2, n7, n) : "";
            String string8 = bl ? Qx.firstClean(GROUP_NAME, string7) : "";
            String string9 = bl ? Qx.resolve(Qx.firstClean(CONDITION, string7), map) : "";
            String string10 = Qx.resolve(Qx.firstClean(CONDITION, string), map);
            String string11 = Qx.and(string6, string9);
            String string12 = Qx.and(string11, string10);
            String string13 = Qx.resolve(Qx.firstClean(CALC, string), map);
            String string14 = Qx.firstClean(TYPE, string);
            String string15 = Qx.firstClean(TITLE, string);
            int n9 = Qx.count(VALIDATION, string);
            String string16 = Qx.firstClean(VALIDATION_MSG, string);
            ArrayList<String> arrayList3 = new ArrayList<>();
            ArrayList<String> arrayList4 = new ArrayList<>();
            Matcher matcher2 = OPTION.matcher(string);
            // Export every category: these values drive allowed-code validation.
            while (matcher2.find()) {
                arrayList3.add(Qx.clean(matcher2.group(1)));
                arrayList4.add(Qx.clean(matcher2.group(2)));
            }
            int n10 = Qx.count(Pattern.compile("class=\\\"option-value\\\"", 2), string);
            StringBuilder stringBuilder = new StringBuilder();
            StringBuilder stringBuilder2 = new StringBuilder();
            StringBuilder stringBuilder3 = new StringBuilder();
            for (int j = 0; j < arrayList3.size(); ++j) {
                if (j > 0) {
                    stringBuilder2.append(' ');
                    stringBuilder3.append('\u001d');
                }
                stringBuilder2.append(arrayList3.get(j));
                stringBuilder3.append(arrayList3.get(j)).append('\u001e').append(j < arrayList4.size() ? arrayList4.get(j) : "");
                if (j >= 8) continue;
                if (stringBuilder.length() > 0) {
                    stringBuilder.append(" | ");
                }
                stringBuilder.append(arrayList3.get(j)).append(' ').append(j < arrayList4.size() ? arrayList4.get(j) : "");
            }
            LinkedHashMap<String, String> linkedHashMap = new LinkedHashMap<>();
            linkedHashMap.put("qx_var", Qx.truncate(string3, 80));
            linkedHashMap.put("qx_section", Qx.truncate(string5, 200));
            linkedHashMap.put("qx_subsection", Qx.truncate(string8, 200));
            linkedHashMap.put("qx_type", Qx.truncate(string14, 60));
            linkedHashMap.put("qx_text", Qx.truncate(string15, 800));
            linkedHashMap.put("qx_section_enable", Qx.truncate(string6, 4000));
            linkedHashMap.put("qx_group_enable", Qx.truncate(string9, 4000));
            linkedHashMap.put("qx_item_enable", Qx.truncate(string10, 4000));
            linkedHashMap.put("qx_parent_enable", Qx.truncate(string11, 8000));
            linkedHashMap.put("qx_enable", Qx.truncate(string12, 12000));
            linkedHashMap.put("qx_enable_deps", "");
            linkedHashMap.put("qx_calc", Qx.truncate(string13, 8000));
            linkedHashMap.put("qx_nval", Integer.toString(n9));
            linkedHashMap.put("qx_valmsg", Qx.truncate(string16, 1000));
            linkedHashMap.put("qx_opts", Qx.truncate(stringBuilder.toString(), 4000));
            linkedHashMap.put("qx_optvals", stringBuilder2.toString());
            linkedHashMap.put("qx_optmap", stringBuilder3.toString());
            linkedHashMap.put("qx_nopts", Integer.toString(n10));
            linkedHashMap.put("qx_section_tri", Qx.triExpression(string6, string3));
            linkedHashMap.put("qx_group_tri", Qx.triExpression(string9, string3));
            linkedHashMap.put("qx_item_tri", Qx.triExpression(string10, string3));
            arrayList2.add(linkedHashMap);
        }
        LinkedHashMap<String, String> linkedHashMap = new LinkedHashMap<>();
        for (Map<String, String> map2 : arrayList2) {
            String string17 = map2.getOrDefault("qx_var", "");
            string = map2.getOrDefault("qx_calc", "");
            if (string17.isEmpty() || string.isEmpty()) continue;
            linkedHashMap.put(string17, string);
        }
        for (Map<String, String> map3 : arrayList2) {
            map3.put("qx_enable_deps", Qx.truncate(Qx.dependencyClosure(map3.getOrDefault("qx_enable", ""), linkedHashMap), 12000));
        }
        return arrayList2;
    }

    static void writeCsv(Path path, Path path2) throws IOException {
        List<Map<String, String>> list = Qx.parse(path);
        try (BufferedWriter bufferedWriter = Files.newBufferedWriter(path2, StandardCharsets.UTF_8)) {
            for (int i = 0; i < HEADER.length; ++i) {
                if (i > 0) {
                    bufferedWriter.write(44);
                }
                bufferedWriter.write(Qx.csv(HEADER[i]));
            }
            bufferedWriter.newLine();
            for (Map<String, String> map : list) {
                for (int i = 0; i < HEADER.length; ++i) {
                    if (i > 0) {
                        bufferedWriter.write(44);
                    }
                    bufferedWriter.write(Qx.csv(map.getOrDefault(HEADER[i], "")));
                }
                bufferedWriter.newLine();
            }
        }
    }

    private static String dependencyClosure(String string, Map<String, String> map) {
        LinkedHashSet<String> linkedHashSet = new LinkedHashSet<>();
        Qx.collectDependencies(string == null ? "" : string, map, linkedHashSet, new LinkedHashSet<>(), 0);
        return String.join(" ", linkedHashSet);
    }

    private static void collectDependencies(String string, Map<String, String> map, Set<String> set, Set<String> set2, int n) {
        if (string == null || string.isEmpty() || n > 12) {
            return;
        }
        String string2 = QUOTED.matcher(Qx.stripComments(string)).replaceAll(" ");
        Matcher matcher = IDENT.matcher(string2);
        while (matcher.find()) {
            String string3 = matcher.group();
            String string4 = string3.toLowerCase(Locale.ROOT);
            if (Qx.isDependencyKeyword(string4)) continue;
            set.add(string3);
            String string5 = map.get(string3);
            if (string5 == null || !set2.add(string3)) continue;
            Qx.collectDependencies(string5, map, set, set2, n + 1);
            set2.remove(string3);
        }
    }

    private static boolean isDependencyKeyword(String string) {
        return string.equals("true") || string.equals("false") || string.equals("null") || string.equals("self") || string.equals("isanswered") || string.equals("missing") || string.equals("contains") || string.equals("value") || string.equals("year") || string.equals("month") || string.equals("day") || string.equals("where") || string.equals("sum") || string.equals("new") || string.equals("datetime") || string.equals("timespan") || string.equals("int") || string.equals("parse") || string.equals("quest") || string.equals("irnd") || string.equals("tostring") || string.equals("substring");
    }

    static String triExpression(String string, String string2) {
        try {
            return new TriParser(string, string2).parse();
        }
        catch (RuntimeException runtimeException) {
            return ".5";
        }
    }

    private static List<String> splitTop(String string, String string2) {
        ArrayList<String> arrayList = new ArrayList<>();
        int n = 0;
        boolean bl = false;
        int n2 = 0;
        for (int i = 0; i < string.length(); ++i) {
            char c = string.charAt(i);
            if (c == '\"' && (i == 0 || string.charAt(i - 1) != '\\')) {
                bl = !bl;
            }
            if (bl) continue;
            if (c == '(') {
                ++n;
            } else if (c == ')') {
                --n;
            }
            if (n != 0 || !string.startsWith(string2, i)) continue;
            arrayList.add(string.substring(n2, i).trim());
            n2 = (i += string2.length() - 1) + 1;
        }
        arrayList.add(string.substring(n2).trim());
        return arrayList;
    }

    private static String stripOuter(String string) {
        String string2 = string.trim();
        while (Qx.balancedOuter(string2)) {
            string2 = string2.substring(1, string2.length() - 1).trim();
        }
        return string2;
    }

    private static boolean balancedOuter(String string) {
        if (string.length() < 2 || string.charAt(0) != '(' || string.charAt(string.length() - 1) != ')') {
            return false;
        }
        int n = 0;
        boolean bl = false;
        for (int i = 0; i < string.length(); ++i) {
            char c = string.charAt(i);
            if (c == '\"' && (i == 0 || string.charAt(i - 1) != '\\')) {
                bl = !bl;
            }
            if (bl) continue;
            if (c == '(') {
                ++n;
            } else if (c == ')') {
                --n;
            }
            if (n == 0 && i < string.length() - 1) {
                return false;
            }
            if (n >= 0) continue;
            return false;
        }
        return n == 0;
    }

    private static String stripComments(String string) {
        return COMMENT.matcher(string).replaceAll("");
    }

    private static Map<String, String> parseAppendix(String string) {
        LinkedHashMap<String, String> linkedHashMap = new LinkedHashMap<>();
        Matcher matcher = APPENDIX.matcher(string);
        while (matcher.find()) {
            linkedHashMap.put(matcher.group(1), Qx.truncate(Qx.clean(matcher.group(2)), 4000));
        }
        return linkedHashMap;
    }

    private static String resolve(String string, Map<String, String> map) {
        String string2 = string == null ? "" : string.trim();
        Matcher matcher = Pattern.compile("^\\[([0-9]+)]$").matcher(string2);
        if (matcher.matches()) {
            return map.getOrDefault(matcher.group(1), string2);
        }
        return string2;
    }

    private static int matchingDivEnd(String string, int n) {
        Matcher matcher = DIV_TOKEN.matcher(string);
        matcher.region(n, string.length());
        int n2 = 1;
        while (matcher.find()) {
            String string2 = matcher.group().toLowerCase(Locale.ROOT);
            n2 = string2.startsWith("<div") ? ++n2 : --n2;
            if (n2 != 0) continue;
            return matcher.end();
        }
        return -1;
    }

    private static String boundedHeader(String string, int n, int n2) {
        if (n < 0 || n >= n2) {
            return "";
        }
        int n3 = Qx.indexQuestionStart(string, n);
        int n4 = n3 >= 0 && n3 < n2 ? n3 : n2;
        return string.substring(n, n4);
    }

    private static int indexQuestionStart(String string, int n) {
        Matcher matcher = QUESTION_START.matcher(string);
        return matcher.find(Math.max(0, n)) ? matcher.start() : -1;
    }

    private static int count(Pattern pattern, String string) {
        int n = 0;
        Matcher matcher = pattern.matcher(string);
        while (matcher.find()) {
            ++n;
        }
        return n;
    }

    private static String firstClean(Pattern pattern, String string) {
        Matcher matcher = pattern.matcher((string == null ? "" : string));
        return matcher.find() ? Qx.clean(matcher.group(1)) : "";
    }

    private static String and(String string, String string2) {
        String string3;
        String string4 = string == null ? "" : string.trim();
        string3 = string2 == null ? "" : string2.trim();
        if (string4.isEmpty()) {
            return string3;
        }
        if (string3.isEmpty()) {
            return string4;
        }
        return "(" + string4 + ") && (" + string3 + ")";
    }

    private static String clean(String string) {
        if (string == null || string.isEmpty()) {
            return "";
        }
        String string2 = HTML_TAG.matcher(string).replaceAll(" ");
        string2 = Qx.decodeNumericEntities(string2);
        string2 = string2.replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'").replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&");
        return string2.replace('\n', ' ').replace('\t', ' ').replaceAll("\\s+", " ").trim();
    }

    private static String decodeNumericEntities(String string) {
        Matcher matcher = ENTITY_NUM.matcher(string);
        StringBuffer stringBuffer = new StringBuffer();
        while (matcher.find()) {
            String string2 = matcher.group(1);
            try {
                int n = string2.startsWith("x") || string2.startsWith("X") ? Integer.parseInt(string2.substring(1), 16) : Integer.parseInt(string2, 10);
                matcher.appendReplacement(stringBuffer, Matcher.quoteReplacement(new String(Character.toChars(n))));
            }
            catch (RuntimeException runtimeException) {
                matcher.appendReplacement(stringBuffer, Matcher.quoteReplacement(matcher.group()));
            }
        }
        matcher.appendTail(stringBuffer);
        return stringBuffer.toString();
    }

    private static String csv(String string) {
        String string2 = string == null ? "" : string;
        string2 = string2.replace("\r", " ").replace("\n", " ").replace("\t", " ");
        return "\"" + string2.replace("\"", "\"\"") + "\"";
    }

    private static String truncate(String string, int n) {
        if (string == null) {
            return "";
        }
        return string.length() <= n ? string : string.substring(0, n);
    }

    private static final class TriParser {
        private final String self;
        private final String input;

        TriParser(String string, String string2) {
            this.self = string2 == null ? "" : string2.trim();
            this.input = Qx.stripComments(string == null ? "" : string).trim();
        }

        String parse() {
            if (this.input.isEmpty()) {
                return "1";
            }
            return this.parseExpr(this.input);
        }

        private String parseExpr(String string) {
            String string2 = Qx.stripOuter(string.trim());
            List<String> list = Qx.splitTop(string2, "||");
            if (list.size() > 1) {
                return this.combine(list, true);
            }
            list = Qx.splitTop(string2, "|");
            if (list.size() > 1) {
                return this.combine(list, true);
            }
            list = Qx.splitTop(string2, "&&");
            if (list.size() > 1) {
                return this.combine(list, false);
            }
            list = Qx.splitTop(string2, "&");
            if (list.size() > 1) {
                return this.combine(list, false);
            }
            if (string2.startsWith("!") && !string2.startsWith("!=")) {
                return "(1-(" + this.parseExpr(string2.substring(1)) + "))";
            }
            return this.atom(string2);
        }

        private String combine(List<String> list, boolean bl) {
            String string = this.parseExpr(list.get(0));
            for (int i = 1; i < list.size(); ++i) {
                String string2 = this.parseExpr(list.get(i));
                string = (bl ? "max" : "min") + "((" + string + "),(" + string2 + "))";
            }
            return string;
        }

        private String atom(String string) {
            String string4 = Qx.stripOuter(string.trim());
            if (string4.isEmpty()) {
                return "1";
            }
            if (this.containsUnsupported(string4)) {
                return ".5";
            }
            ArrayList<String> arrayList = new ArrayList<>();
            Matcher matcher = Pattern.compile("!?IsAnswered\\(\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\)", 2).matcher(string4);
            while (matcher.find()) {
                arrayList.add(matcher.group(1));
            }
            String string5 = string4;
            string5 = string5.replaceAll("(?i)==\\s*true\\b", "==1");
            string5 = string5.replaceAll("(?i)==\\s*false\\b", "==0");
            string5 = string5.replaceAll("(?i)!=\\s*true\\b", "!=1");
            string5 = string5.replaceAll("(?i)!=\\s*false\\b", "!=0");
            string5 = string5.replaceAll("(?i)\\btrue\\b", "1");
            string5 = string5.replaceAll("(?i)\\bfalse\\b", "0");
            if (!this.self.isEmpty()) {
                string5 = string5.replaceAll("(?i)\\bself\\b", Matcher.quoteReplacement(this.self));
            }
            string5 = string5.replaceAll("(?i)!IsAnswered\\(\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\)", "missing($1)");
            string5 = string5.replaceAll("(?i)IsAnswered\\(\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*\\)", "!missing($1)");
            string5 = string5.replaceAll("([A-Za-z_][A-Za-z0-9_]*)\\.Contains\\(\\s*([0-9-]+)\\s*\\)", "$1__$2==1");
            if ((string5 = string5.trim()).contains("&&") || string5.contains("||")) {
                return ".5";
            }
            String string6 = QUOTED.matcher(string5).replaceAll(" ");
            Matcher matcher2 = IDENT.matcher(string6);
            ArrayList<String> arrayList2 = new ArrayList<>();
            while (matcher2.find()) {
                String string3 = matcher2.group();
                String string7 = string3.toLowerCase(Locale.ROOT);
                if (this.isReservedIdentifier(string7) || arrayList.stream().anyMatch(string2 -> string2.equalsIgnoreCase(string3)) || arrayList2.contains(string3)) continue;
                arrayList2.add(string3);
            }
            if (this.isNullSafeEqualityAtom(string5)) {
                return "((" + string5 + ")!=0)";
            }
            if (this.isSimpleBooleanIdentifier(string5)) {
                return "cond(missing(" + string5 + "),0,(" + string5 + "!=0))";
            }
            StringBuilder string3 = new StringBuilder();
            for (String string8 : arrayList2) {
                if (string3.length() > 0) {
                    string3.append(" | ");
                }
                string3.append("missing(").append(string8).append(')');
            }
            if (string3.length() == 0) {
                return "cond(missing((" + string5 + ")), .5, ((" + string5 + ")!=0))";
            }
            return "cond((" + String.valueOf(string3) + ") | missing((" + string5 + ")), .5, ((" + string5 + ")!=0))";
        }

        private boolean isNullSafeEqualityAtom(String string) {
            String string2 = string.trim();
            if (!string2.contains("==") && !string2.contains("!=")) {
                return false;
            }
            String string3 = string2.replace("!=", "");
            return !string3.contains("<") && !string3.contains(">") && !string2.contains("+") && !string2.contains("*") && !string2.contains("/");
        }

        private boolean isSimpleBooleanIdentifier(String string) {
            return string.trim().matches("[A-Za-z_][A-Za-z0-9_]*");
        }

        private boolean containsUnsupported(String string) {
            String string2 = string.toLowerCase(Locale.ROOT);
            return string2.contains("?") || string2.contains("new[]{") || string2.contains(".where(") || string2.contains(".sum(") || string2.contains(".value.") || string2.contains("datetime") || string2.contains("timespan") || string2.contains("rost") || string2.contains("@rowcode");
        }

        private boolean isReservedIdentifier(String string) {
            return string.equals("missing") || string.equals("cond") || string.equals("min") || string.equals("max") || string.equals("inlist") || string.equals("inrange") || string.equals("abs") || string.equals("floor") || string.equals("ceil") || string.equals("int") || string.equals("round") || string.equals("true") || string.equals("false") || string.equals("self") || string.equals("isanswered");
        }
    }
}
