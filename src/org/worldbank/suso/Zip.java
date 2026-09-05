package org.worldbank.suso;

import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.FileVisitResult;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermissions;
import java.nio.channels.FileChannel;
import java.nio.channels.Channels;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.text.Normalizer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.CRC32;
import java.util.zip.Inflater;
import java.util.zip.InflaterInputStream;

/** Whole-archive ZIP/ZipCrypto validation and exact-folder publication with backups. */
final class Zip {
    private static final int[] CRC = new int[256];
    private static final long MAX_ENTRIES = 1_000_000L;
    private static final long MAX_ENTRY_SIZE = 50L * 1024 * 1024 * 1024;
    private static final long MAX_TOTAL_SIZE = 100L * 1024 * 1024 * 1024;

    private Zip() {}

    private static final String MANIFEST = ".suso-manifest.json";

    static Result extract(String archive, String destination, String password) {
        return extract(archive, destination, password, null);
    }

    static Result extract(String archive, String destination, String password, ZipPublisher.FailureInjector injector) {
        Result result = new Result();
        result.dir = destination;
        byte[] passwordBytes = password == null ? new byte[0]
                : password.getBytes(StandardCharsets.UTF_8);
        ZipPublisher publisher = null;
        try {
            Path requested = Paths.get(destination).toAbsolutePath().normalize();
            result.dir = requested.toString();
            publisher = new ZipPublisher(requested, Paths.get(archive), injector, result);
            publisher.begin();
            Path stage = publisher.stage;
            List<Map<String, Object>> manifestEntries = new ArrayList<>();
            List<String> names = new ArrayList<>();
            List<String> archiveDirectories = new ArrayList<>();
            long totalWritten = 0L;
            try (RandomAccessFile raf = new RandomAccessFile(archive, "r")) {
                long fileLength = raf.length();
                long eocd = findEOCD(raf, fileLength);
                if (eocd < 0) throw new IOException("not a ZIP file (no end-of-central-directory record)");
                raf.seek(eocd + 4);
                if (readU16(raf) != 0 || readU16(raf) != 0) {
                    throw new IOException("multi-volume ZIP archives are not supported");
                }
                long diskCount = readU16(raf);
                long entryCount = readU16(raf);
                long centralSize = readU32(raf);
                long centralOffset = readU32(raf);
                long expectedEnd = eocd;
                if (diskCount != entryCount) throw new IOException("incomplete multi-volume ZIP archive");
                if (centralOffset == 0xffffffffL || entryCount == 0xffffL || centralSize == 0xffffffffL) {
                    long zip64 = findZip64EOCD(raf, eocd);
                    if (zip64 < 0) throw new IOException("invalid ZIP64 end record");
                    expectedEnd = zip64;
                    raf.seek(zip64 + 16);
                    if (readU32(raf) != 0 || readU32(raf) != 0) throw new IOException("multi-volume ZIP64 archive");
                    diskCount = readU64(raf);
                    entryCount = readU64(raf);
                    centralSize = readU64(raf);
                    centralOffset = readU64(raf);
                    if (diskCount != entryCount) throw new IOException("incomplete ZIP64 archive");
                }
                if (entryCount < 0 || entryCount > MAX_ENTRIES) {
                    throw new IOException("unreasonable ZIP entry count: " + entryCount);
                }
                if (centralOffset > expectedEnd || centralSize != expectedEnd - centralOffset) {
                    throw new IOException("invalid central-directory bounds");
                }
                List<Entry> entries = new ArrayList<>();
                Map<String, String> spellings = new HashMap<>();
                Set<String> explicitNames = new HashSet<>();
                Set<String> files = new HashSet<>();
                Set<String> directories = new HashSet<>();
                long central = centralOffset;
                long declaredTotal = 0L;
                for (long index = 0; index < entryCount; index++) {
                    Entry entry = readEntry(raf, central, fileLength);
                    entry.centralOffset = centralOffset;
                    central = entry.nextCentral;
                    if (central > centralOffset + centralSize) throw new IOException("central-directory entry exceeds bounds");
                    entry.relative = safeName(entry.name);
                    registerName(entry, spellings, explicitNames, files, directories);
                    if (entry.directory && entry.uncompressedSize != 0) {
                        throw new IOException("ZIP directory contains file data: " + entry.name);
                    }
                    if (entry.uncompressedSize > MAX_ENTRY_SIZE
                            || entry.uncompressedSize > MAX_TOTAL_SIZE - declaredTotal) {
                        throw new IOException("ZIP size limit exceeded for " + entry.name);
                    }
                    declaredTotal += entry.uncompressedSize;
                    entries.add(entry);
                }
                if (central != centralOffset + centralSize) {
                    throw new IOException("central-directory size/count mismatch");
                }
                for (Entry entry : entries) {
                    Path target = stage.resolve(entry.relative);
                    createSafeDirectories(stage, entry.directory ? target : target.getParent());
                    Map<String, Object> verified = extractEntry(raf, entry,
                            entry.directory ? null : target, passwordBytes, result);
                    if (!entry.directory) {
                        manifestEntries.add(verified);
                        names.add(entry.relative);
                        totalWritten += entry.uncompressedSize;
                    } else {
                        archiveDirectories.add(entry.relative);
                    }
                }
            }
            Map<String, Object> manifest = new LinkedHashMap<>();
            manifest.put("format", "suso-extraction-manifest");
            manifest.put("version", 2);
            manifest.put("scope", "archive-files");
            manifest.put("archive", Paths.get(archive).getFileName().toString());
            manifest.put("completed_utc", java.time.Instant.now().toString());
            manifest.put("file_count", names.size());
            manifest.put("bytes", totalWritten);
            manifest.put("files", manifestEntries);
            Path manifestPath = stage.resolve(MANIFEST);
            createPrivateFile(manifestPath);
            try (FileChannel channel = FileChannel.open(manifestPath, StandardOpenOption.WRITE);
                 OutputStream out = Channels.newOutputStream(channel)) {
                out.write((Json.write(manifest) + "\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
                channel.force(true);
            }
            publisher.publish(names, archiveDirectories, manifestPath);
            result.files = names.size();
            result.names.addAll(names);
            result.bytes = totalWritten;
        } catch (Throwable ex) {
            result.files = 0;
            result.skipped = 0;
            result.names.clear();
            result.bytes = 0;
            result.error = ex.getClass().getSimpleName() + ": "
                    + (ex.getMessage() == null ? "" : ex.getMessage());
        } finally {
            Arrays.fill(passwordBytes, (byte)0);
            if (publisher != null) publisher.finish();
            if (result.transactionDir != null && result.error != null) {
                // An unresolved transaction is explicitly unknown, never a false
                // report that zero destination files may have changed.
                result.files = -1;
                result.bytes = -1;
            }
        }
        return result;
    }

    static void createPrivateDirectory(Path directory) throws IOException {
        try {
            Files.createDirectory(directory,
                    PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rwx------")));
        } catch (UnsupportedOperationException ex) {
            Files.createDirectory(directory);
        }
    }

    static void createPrivateFile(Path file) throws IOException {
        try {
            Files.createFile(file, PosixFilePermissions.asFileAttribute(
                    PosixFilePermissions.fromString("rw-------")));
        } catch (UnsupportedOperationException ex) {
            Files.createFile(file);
        }
    }

    static void deleteTree(Path root) throws IOException {
        Files.walkFileTree(root, new SimpleFileVisitor<Path>() {
            @Override public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                Files.delete(file);
                return FileVisitResult.CONTINUE;
            }
            @Override public FileVisitResult postVisitDirectory(Path directory, IOException error) throws IOException {
                if (error != null) throw error;
                Files.delete(directory);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    private static Entry readEntry(RandomAccessFile raf, long central,
            long fileLength) throws IOException {
        if (central < 0 || central + 46 > fileLength) throw new IOException("truncated central directory");
        raf.seek(central);
        if (readU32(raf) != 0x02014b50L) throw new IOException("invalid central-directory signature");
        raf.seek(central + 4);
        int madeBy = readU16(raf);
        raf.seek(central + 38);
        long externalAttributes = readU32(raf);
        int unixType = (int)((externalAttributes >>> 16) & 0170000);
        if ((madeBy >>> 8) == 3 && unixType != 0 && unixType != 0100000 && unixType != 0040000) {
            throw new IOException("ZIP symlink/special file rejected");
        }
        raf.seek(central + 8);
        int flags = readU16(raf);
        int method = readU16(raf);
        int modTime = readU16(raf);
        raf.seek(central + 16);
        long expectedCrc = readU32(raf);
        long compressed = readU32(raf);
        long uncompressed = readU32(raf);
        int nameLength = readU16(raf);
        int extraLength = readU16(raf);
        int commentLength = readU16(raf);
        int diskStart = readU16(raf);
        if (diskStart != 0 && diskStart != 0xffff) throw new IOException("multi-volume ZIP entry");
        raf.seek(central + 42);
        long localOffset = readU32(raf);
        if (nameLength < 0 || central + 46L + nameLength + extraLength + commentLength > fileLength) {
            throw new IOException("truncated central-directory entry");
        }
        byte[] nameBytes = new byte[nameLength];
        raf.seek(central + 46);
        raf.readFully(nameBytes);
        String name = decodeName(nameBytes, flags);

        if (compressed == 0xffffffffL || uncompressed == 0xffffffffL || localOffset == 0xffffffffL || diskStart == 0xffff) {
            long p = central + 46L + nameLength;
            long end = p + extraLength;
            boolean found = false;
            while (p + 4 <= end) {
                raf.seek(p);
                int tag = readU16(raf);
                int size = readU16(raf);
                long value = p + 4;
                if (value + size > end) throw new IOException("invalid ZIP extra field");
                if (tag == 1) {
                    int required = (uncompressed == 0xffffffffL ? 8 : 0)
                            + (compressed == 0xffffffffL ? 8 : 0)
                            + (localOffset == 0xffffffffL ? 8 : 0) + (diskStart == 0xffff ? 4 : 0);
                    if (size < required) throw new IOException("truncated ZIP64 extra field");
                    if (uncompressed == 0xffffffffL) { raf.seek(value); uncompressed = readU64(raf); value += 8; }
                    if (compressed == 0xffffffffL) { raf.seek(value); compressed = readU64(raf); value += 8; }
                    if (localOffset == 0xffffffffL) { raf.seek(value); localOffset = readU64(raf); value += 8; }
                    if (diskStart == 0xffff) { raf.seek(value); if (readU32(raf) != 0) throw new IOException("multi-volume ZIP64 entry"); }
                    found = true;
                    break;
                }
                p = value + size;
            }
            if (!found) throw new IOException("missing ZIP64 extra field");
        }
        if (compressed < 0 || uncompressed < 0 || localOffset < 0) {
            throw new IOException("unsupported ZIP64 value");
        }
        if ((flags & 0x40) != 0) throw new IOException("strong ZIP encryption is not supported");
        if (method != 0 && method != 8) throw new IOException("unsupported compression method " + method);
        Entry entry = new Entry();
        entry.name = name;
        entry.flags = flags;
        entry.method = method;
        entry.modTime = modTime;
        entry.expectedCrc = expectedCrc;
        entry.compressedSize = compressed;
        entry.uncompressedSize = uncompressed;
        entry.localOffset = localOffset;
        entry.directory = name.endsWith("/") || name.endsWith("\\");
        entry.nextCentral = central + 46L + nameLength + extraLength + commentLength;
        return entry;
    }

    private static Map<String, Object> extractEntry(RandomAccessFile raf, Entry entry, Path target,
            byte[] password, Result result) throws IOException {
        if (entry.localOffset > raf.length() - 30) throw new IOException("truncated local header for " + entry.name);
        raf.seek(entry.localOffset);
        if (readU32(raf) != 0x04034b50L) throw new IOException("invalid local header for " + entry.name);
        raf.seek(entry.localOffset + 6);
        if (readU16(raf) != entry.flags || readU16(raf) != entry.method) {
            throw new IOException("local/central ZIP header mismatch for " + entry.name);
        }
        raf.seek(entry.localOffset + 14);
        long localCrc = readU32(raf), localCompressed = readU32(raf), localSize = readU32(raf);
        boolean zip64Local = localCompressed == 0xffffffffL || localSize == 0xffffffffL;
        int localNameLength = readU16(raf);
        int localExtraLength = readU16(raf);
        byte[] localName = new byte[localNameLength];
        raf.readFully(localName);
        if (!entry.name.equals(decodeName(localName, entry.flags))) {
            throw new IOException("local/central ZIP filename mismatch for " + entry.name);
        }
        long dataOffset = entry.localOffset + 30L + localNameLength + localExtraLength;
        if (dataOffset > entry.centralOffset || entry.compressedSize > entry.centralOffset - dataOffset) {
            throw new IOException("truncated data for " + entry.name);
        }
        if (zip64Local) {
            long p = entry.localOffset + 30L + localNameLength;
            boolean found = false;
            while (p + 4 <= dataOffset) {
                raf.seek(p);
                int tag = readU16(raf), size = readU16(raf);
                long value = p + 4;
                if (value + size > dataOffset) throw new IOException("invalid local ZIP extra field");
                if (tag == 1) {
                    int required = (localSize == 0xffffffffL ? 8 : 0) + (localCompressed == 0xffffffffL ? 8 : 0);
                    if (size < required) throw new IOException("truncated local ZIP64 extra field");
                    if (localSize == 0xffffffffL) { raf.seek(value); localSize = readU64(raf); value += 8; }
                    if (localCompressed == 0xffffffffL) { raf.seek(value); localCompressed = readU64(raf); }
                    found = true;
                    break;
                }
                p = value + size;
            }
            if (!found) throw new IOException("missing local ZIP64 extra field");
        }
        boolean descriptor = (entry.flags & 8) != 0;
        if ((!descriptor || localCrc != 0) && localCrc != entry.expectedCrc
                || (!descriptor || localSize != 0) && localSize != entry.uncompressedSize
                || (!descriptor || localCompressed != 0) && localCompressed != entry.compressedSize) {
            throw new IOException("local/central ZIP CRC or size mismatch for " + entry.name);
        }
        if (descriptor) verifyDescriptor(raf, dataOffset + entry.compressedSize, entry, zip64Local);
        raf.seek(dataOffset);
        RafInputStream bounded = new RafInputStream(raf, entry.compressedSize);
        InputStream compressed = bounded;
        if ((entry.flags & 1) != 0) {
            if (password.length == 0) {
                result.badPassword = true;
                throw new IOException("password required for encrypted ZIP entry " + entry.name);
            }
            int[] keys = initKeys(password);
            byte[] header = new byte[12];
            readFully(compressed, header);
            for (int i = 0; i < header.length; i++) header[i] = decryptByte(keys, header[i]);
            int check = (entry.flags & 8) != 0 ? (entry.modTime >>> 8) & 0xff
                    : (int)((entry.expectedCrc >>> 24) & 0xff);
            if ((header[11] & 0xff) != check) {
                result.badPassword = true;
                throw new IOException("wrong ZIP password for " + entry.name);
            }
            compressed = new DecryptInputStream(compressed, keys);
        }
        Inflater inflater = entry.method == 8 ? new Inflater(true) : null;
        InputStream plain = inflater != null
                ? new InflaterInputStream(compressed, inflater, 65536) : compressed;
        long count = 0L;
        CRC32 crc = new CRC32();
        MessageDigest digest;
        try { digest = MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException ex) { throw new IOException("SHA-256 unavailable", ex); }
        try {
            if (target != null) createPrivateFile(target);
            try (InputStream in = plain;
                 FileChannel channel = target == null ? null : FileChannel.open(target, StandardOpenOption.WRITE);
                 OutputStream out = channel == null ? OutputStream.nullOutputStream() : Channels.newOutputStream(channel)) {
                byte[] buffer = new byte[65536];
                int n;
                while ((n = in.read(buffer)) != -1) {
                    count += n;
                    if (count > MAX_ENTRY_SIZE || count > entry.uncompressedSize) {
                        throw new IOException("expanded size exceeds ZIP metadata for " + entry.name);
                    }
                    crc.update(buffer, 0, n);
                    digest.update(buffer, 0, n);
                    out.write(buffer, 0, n);
                }
                if (count != entry.uncompressedSize) {
                    throw new IOException("incomplete ZIP entry " + entry.name + ": expected "
                            + entry.uncompressedSize + " bytes, received " + count);
                }
                if (crc.getValue() != entry.expectedCrc) {
                    if ((entry.flags & 1) != 0) result.badPassword = true;
                    throw new IOException("CRC mismatch for ZIP entry " + entry.name);
                }
                if (bounded.remaining != 0 || (inflater != null && (!inflater.finished() || inflater.getRemaining() != 0))) {
                    throw new IOException("compressed size mismatch for ZIP entry " + entry.name);
                }
                out.flush();
                if (channel != null) channel.force(true);
            }
        } finally {
            if (inflater != null) inflater.end();
        }
        Map<String, Object> verified = new LinkedHashMap<>();
        verified.put("path", entry.relative);
        verified.put("bytes", count);
        verified.put("crc32", String.format(Locale.ROOT, "%08x", crc.getValue()));
        verified.put("sha256", hex(digest.digest()));
        return verified;
    }

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            out.append(Character.forDigit((value >>> 4) & 15, 16));
            out.append(Character.forDigit(value & 15, 16));
        }
        return out.toString();
    }

    private static void verifyDescriptor(RandomAccessFile raf, long offset, Entry entry,
            boolean zip64) throws IOException {
        boolean wide = zip64 || entry.compressedSize > 0xffffffffL || entry.uncompressedSize > 0xffffffffL;
        int length = wide ? 20 : 12;
        for (int signatureBytes : new int[]{4, 0}) {
            if (offset > entry.centralOffset - length - signatureBytes) continue;
            raf.seek(offset);
            if (signatureBytes == 4 && readU32(raf) != 0x08074b50L) continue;
            long crc = readU32(raf);
            long compressed = wide ? readU64(raf) : readU32(raf);
            long plain = wide ? readU64(raf) : readU32(raf);
            if (crc == entry.expectedCrc && compressed == entry.compressedSize && plain == entry.uncompressedSize) return;
        }
        throw new IOException("ZIP data-descriptor CRC or size mismatch for " + entry.name);
    }

    private static String decodeName(byte[] bytes, int flags) throws IOException {
        Charset charset = (flags & 0x800) != 0 ? StandardCharsets.UTF_8 : Charset.forName("CP437");
        return charset.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString();
    }

    private static String safeName(String rawName) throws IOException {
        if (rawName == null || rawName.isEmpty()) throw new IOException("empty ZIP entry name");
        String name = rawName.replace('\\', '/');
        if (name.startsWith("/")) throw new IOException("absolute ZIP entry path rejected: " + rawName);
        if (name.endsWith("/")) name = name.substring(0, name.length() - 1);
        String[] parts = name.split("/", -1);
        for (String part : parts) {
            if (part.isEmpty() || part.equals(".") || part.equals("..")) {
                throw new IOException("ambiguous/traversal ZIP path rejected: " + rawName);
            }
            if (part.endsWith(".") || part.endsWith(" ") || part.matches(".*[<>:\"|?*\\\\].*")) {
                throw new IOException("Windows-unsafe ZIP path rejected: " + rawName);
            }
            for (int i = 0; i < part.length(); i++) {
                if (part.charAt(i) < 32 || part.charAt(i) == 127) throw new IOException("control character in ZIP name");
            }
            String base = part.split("\\.", 2)[0].stripTrailing().toUpperCase(Locale.ROOT);
            if (base.matches("CON|PRN|AUX|NUL|CONIN\\$|CONOUT\\$|COM[1-9¹²³]|LPT[1-9¹²³]")) {
                throw new IOException("reserved Windows device name in ZIP: " + rawName);
            }
        }
        for (String reserved : List.of(MANIFEST, ZipPublisher.MANIFESTS, ZipPublisher.BACKUPS,
                ZipPublisher.TRANSACTIONS, ZipPublisher.LOCK)) {
            if (canonical(parts[0]).equals(canonical(reserved))) throw new IOException("reserved SuSo internal path in ZIP");
        }
        return String.join("/", parts);
    }

    private static String canonical(String name) {
        return Normalizer.normalize(name, Normalizer.Form.NFC).toUpperCase(Locale.ROOT);
    }

    private static void registerName(Entry entry, Map<String, String> spellings,
            Set<String> explicitNames, Set<String> files, Set<String> directories) throws IOException {
        String path = entry.relative;
        String key = canonical(path);
        if (!explicitNames.add(key)) throw new IOException("duplicate/aliased ZIP path: " + entry.name);
        String[] parts = path.split("/");
        String prefix = "";
        for (int i = 0; i < parts.length; i++) {
            prefix += (i == 0 ? "" : "/") + parts[i];
            String normalized = canonical(prefix);
            String old = spellings.putIfAbsent(normalized, prefix);
            if (old != null && !old.equals(prefix)) throw new IOException("case/Unicode-aliased ZIP path: " + entry.name);
            boolean directory = i < parts.length - 1 || entry.directory;
            if (directory) {
                if (files.contains(normalized)) throw new IOException("ZIP file/directory collision: " + entry.name);
                directories.add(normalized);
            } else {
                if (directories.contains(normalized)) throw new IOException("ZIP file/directory collision: " + entry.name);
                files.add(normalized);
            }
        }
    }

    static void createSafeDirectories(Path root, Path directory) throws IOException {
        if (directory == null || !directory.startsWith(root)) throw new IOException("invalid ZIP directory");
        Path current = root;
        Path relative = root.relativize(directory);
        for (Path part : relative) {
            current = current.resolve(part);
            if (Files.exists(current, LinkOption.NOFOLLOW_LINKS)) {
                if (Files.isSymbolicLink(current) || !Files.isDirectory(current, LinkOption.NOFOLLOW_LINKS)) {
                    throw new IOException("unsafe ZIP path component: " + current);
                }
            } else {
                try {
                    Files.createDirectory(current, PosixFilePermissions.asFileAttribute(
                            PosixFilePermissions.fromString("rwx------")));
                } catch (UnsupportedOperationException ex) {
                    Files.createDirectory(current);
                }
            }
        }
    }

    private static void readFully(InputStream in, byte[] value) throws IOException {
        int offset = 0;
        while (offset < value.length) {
            int n = in.read(value, offset, value.length - offset);
            if (n < 0) throw new IOException("truncated encrypted ZIP header");
            offset += n;
        }
    }

    private static int[] initKeys(byte[] password) {
        int[] keys = {0x12345678, 0x23456789, 0x34567890};
        for (byte b : password) updateKeys(keys, b);
        return keys;
    }

    private static void updateKeys(int[] keys, byte value) {
        keys[0] = crc32(keys[0], value);
        keys[1] = keys[1] + (keys[0] & 0xff);
        keys[1] = keys[1] * 134775813 + 1;
        keys[2] = crc32(keys[2], (byte)(keys[1] >>> 24));
    }

    private static int crc32(int old, byte value) {
        return (old >>> 8) ^ CRC[(old ^ value) & 0xff];
    }

    private static byte decryptByte(int[] keys, byte encrypted) {
        int temp = (keys[2] | 2) & 0xffff;
        int plain = (encrypted & 0xff) ^ ((temp * (temp ^ 1)) >>> 8 & 0xff);
        updateKeys(keys, (byte)plain);
        return (byte)plain;
    }

    private static int readU16(RandomAccessFile raf) throws IOException {
        int a = raf.read(); int b = raf.read();
        if ((a | b) < 0) throw new IOException("unexpected end of ZIP");
        return a | b << 8;
    }

    private static long readU32(RandomAccessFile raf) throws IOException {
        long a = raf.read(); long b = raf.read(); long c = raf.read(); long d = raf.read();
        if ((a | b | c | d) < 0) throw new IOException("unexpected end of ZIP");
        return a | b << 8 | c << 16 | d << 24;
    }

    private static long readU64(RandomAccessFile raf) throws IOException {
        long low = readU32(raf), high = readU32(raf);
        if ((high & 0x80000000L) != 0) throw new IOException("ZIP64 value too large");
        return low | high << 32;
    }

    private static long findEOCD(RandomAccessFile raf, long length) throws IOException {
        long start = Math.max(0, length - 65557L);
        raf.seek(start);
        byte[] tail = new byte[(int)(length - start)];
        raf.readFully(tail);
        for (int i = tail.length - 22; i >= 0; i--) {
            if ((tail[i] & 0xff) == 0x50 && (tail[i + 1] & 0xff) == 0x4b
                    && (tail[i + 2] & 0xff) == 0x05 && (tail[i + 3] & 0xff) == 0x06
                    && i + 22 + ((tail[i + 20] & 255) | (tail[i + 21] & 255) << 8) == tail.length) {
                long candidate = start + i;
                try {
                    raf.seek(candidate + 10);
                    long entries = readU16(raf);
                    long size = readU32(raf), offset = readU32(raf), end = candidate;
                    if (entries == 0xffff || size == 0xffffffffL || offset == 0xffffffffL) {
                        long zip64 = findZip64EOCD(raf, candidate);
                        if (zip64 < 0) continue;
                        raf.seek(zip64 + 32);
                        entries = readU64(raf); size = readU64(raf); offset = readU64(raf);
                        end = zip64;
                    }
                    // Ignore signatures in comments, including forged empty archives.
                    if (entries == 0 && (offset != 0 || size != 0)) continue;
                    if (offset <= end && size == end - offset) return candidate;
                } catch (IOException malformedCandidate) {
                    // A comment may contain arbitrary bytes, including ZIP signatures.
                }
            }
        }
        return -1;
    }

    private static long findZip64EOCD(RandomAccessFile raf, long eocd) throws IOException {
        long locator = eocd - 20;
        if (locator < 0) return -1;
        raf.seek(locator);
        if (readU32(raf) != 0x07064b50L) return -1;
        if (readU32(raf) != 0) return -1;
        long offset = readU64(raf);
        if (readU32(raf) != 1 || offset > locator - 56) return -1;
        raf.seek(offset);
        if (readU32(raf) != 0x06064b50L) return -1;
        long recordSize = readU64(raf);
        return recordSize >= 44 && recordSize == locator - offset - 12 ? offset : -1;
    }

    static {
        for (int i = 0; i < 256; i++) {
            int value = i;
            for (int bit = 0; bit < 8; bit++) {
                value = (value & 1) != 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
            }
            CRC[i] = value;
        }
    }

    private static final class Entry {
        String name;
        String relative;
        int flags;
        int method;
        int modTime;
        long expectedCrc;
        long compressedSize;
        long uncompressedSize;
        long localOffset;
        long centralOffset;
        long nextCentral;
        boolean directory;
    }

    private static final class RafInputStream extends InputStream {
        private final RandomAccessFile raf;
        private long remaining;
        RafInputStream(RandomAccessFile raf, long remaining) {
            this.raf = raf; this.remaining = remaining;
        }
        @Override public int read() throws IOException {
            if (remaining == 0) return -1;
            int value = raf.read();
            if (value < 0) throw new IOException("truncated ZIP entry");
            remaining--;
            return value;
        }
        @Override public int read(byte[] buffer, int offset, int length) throws IOException {
            if (length == 0) return 0;
            if (remaining == 0) return -1;
            int wanted = (int)Math.min(length, remaining);
            int count = raf.read(buffer, offset, wanted);
            if (count < 0) throw new IOException("truncated ZIP entry");
            remaining -= count;
            return count;
        }
    }

    private static final class DecryptInputStream extends FilterInputStream {
        private final int[] keys;
        DecryptInputStream(InputStream in, int[] keys) { super(in); this.keys = keys; }
        @Override public int read() throws IOException {
            int value = super.read();
            return value < 0 ? -1 : decryptByte(keys, (byte)value) & 0xff;
        }
        @Override public int read(byte[] buffer, int offset, int length) throws IOException {
            int count = super.read(buffer, offset, length);
            for (int i = 0; i < count; i++) buffer[offset + i] = decryptByte(keys, buffer[offset + i]);
            return count;
        }
    }

    static final class Result {
        int files;
        int skipped;
        String dir;
        String error;
        String notice;
        String manifest;
        String backupDir;
        String transactionDir;
        long bytes;
        boolean badPassword;
        final List<String> names = new ArrayList<>();
    }
}
