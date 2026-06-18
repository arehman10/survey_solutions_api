package org.worldbank.suso;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.Inflater;

/**
 * Minimal, dependency-free ZIP extractor.
 *
 * <p>Supports the "stored" (0) and "deflate" (8) compression methods, and the traditional
 * PKWARE ZipCrypto stream cipher (the weak password scheme that Survey Solutions uses for
 * password-protected exports, and that Python's {@code zipfile} can also open). It is NOT a
 * full ZIP implementation: WinZip AES encryption is not supported (Survey Solutions does not
 * use it; if encountered, the entry is reported and skipped).</p>
 *
 * <p>The archive is read via its central directory so that compressed sizes are known up front
 * (avoiding data-descriptor ambiguity). Basic ZIP64 size fields are honored.</p>
 */
final class Zip {

    private Zip() {}

    /** Result of an extraction. */
    static final class Result {
        int    files;       // entries written
        int    skipped;     // entries skipped (e.g. unsupported encryption)
        String dir;         // output directory
        String error;       // non-null on hard failure
        boolean badPassword; // true if decryption verification failed (wrong/empty password)
        final List<String> names = new ArrayList<>();
    }

    // ----- CRC32 table for ZipCrypto key updates -----
    private static final int[] CRC = new int[256];
    static {
        for (int i = 0; i < 256; i++) {
            int c = i;
            for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
            CRC[i] = c;
        }
    }

    /**
     * Extract {@code zipFile} into {@code destDir}. If {@code password} is non-null/non-empty it is
     * used to decrypt encrypted entries; an empty password is tried as-is (some archives use one).
     */
    static Result extract(String zipFile, String destDir, String password) {
        Result r = new Result();
        r.dir = destDir;
        byte[] pw = (password == null) ? new byte[0] : password.getBytes(StandardCharsets.UTF_8);
        File outRoot = new File(destDir);
        if (!outRoot.exists()) outRoot.mkdirs();

        try (RandomAccessFile raf = new RandomAccessFile(zipFile, "r")) {
            long len = raf.length();
            long eocd = findEOCD(raf, len);
            if (eocd < 0) { r.error = "not a ZIP file (no end-of-central-directory record)"; return r; }

            raf.seek(eocd + 10);
            int totalEntries = readU16(raf);
            raf.seek(eocd + 16);
            long cdOffset = readU32(raf);
            // ZIP64: if markers present, locate the zip64 EOCD for the real offset/count.
            if (cdOffset == 0xFFFFFFFFL || totalEntries == 0xFFFF) {
                long z64 = findZip64EOCD(raf, eocd);
                if (z64 >= 0) {
                    raf.seek(z64 + 24);
                    totalEntries = (int) readU64(raf);   // entries on this disk
                    raf.seek(z64 + 48);
                    cdOffset = readU64(raf);
                }
            }

            long pos = cdOffset;
            for (int i = 0; i < totalEntries; i++) {
                raf.seek(pos);
                long sig = readU32(raf);
                if (sig != 0x02014b50L) break;                 // not a central-dir header
                raf.seek(pos + 8);
                int flag   = readU16(raf);
                int method = readU16(raf);
                raf.seek(pos + 20);
                long compSize   = readU32(raf);
                long uncompSize = readU32(raf);
                int  nameLen    = readU16(raf);
                int  extraLen   = readU16(raf);
                int  commentLen = readU16(raf);
                raf.seek(pos + 42);
                long localOff   = readU32(raf);
                byte[] nameB = new byte[nameLen];
                raf.seek(pos + 46);
                raf.readFully(nameB);
                String name = new String(nameB, StandardCharsets.UTF_8);

                // ZIP64 extra (id 0x0001): real sizes/offset live here when the 32-bit fields are 0xFFFFFFFF.
                if (compSize == 0xFFFFFFFFL || uncompSize == 0xFFFFFFFFL || localOff == 0xFFFFFFFFL) {
                    long ep = pos + 46 + nameLen;
                    long eend = ep + extraLen;
                    while (ep + 4 <= eend) {
                        raf.seek(ep);
                        int id = readU16(raf), sz = readU16(raf);
                        long fp = ep + 4;
                        if (id == 0x0001) {
                            if (uncompSize == 0xFFFFFFFFL) { raf.seek(fp); uncompSize = readU64(raf); fp += 8; }
                            if (compSize   == 0xFFFFFFFFL) { raf.seek(fp); compSize   = readU64(raf); fp += 8; }
                            if (localOff   == 0xFFFFFFFFL) { raf.seek(fp); localOff   = readU64(raf); fp += 8; }
                            break;
                        }
                        ep += 4 + sz;
                    }
                }

                pos = pos + 46 + nameLen + extraLen + commentLen;   // next central-dir entry

                boolean isDir = name.endsWith("/");
                File out = new File(outRoot, name);
                if (isDir) { out.mkdirs(); continue; }
                File parent = out.getParentFile();
                if (parent != null && !parent.exists()) parent.mkdirs();

                // --- read the local header to find the data start ---
                raf.seek(localOff);
                long lsig = readU32(raf);
                if (lsig != 0x04034b50L) { r.skipped++; continue; }
                raf.seek(localOff + 26);
                int lNameLen  = readU16(raf);
                int lExtraLen = readU16(raf);
                long dataStart = localOff + 30 + lNameLen + lExtraLen;

                boolean encrypted = (flag & 0x1) != 0;
                boolean strongOrAes = (flag & 0x40) != 0;      // AES / strong encryption marker
                if (encrypted && strongOrAes) { r.skipped++; continue; }

                raf.seek(dataStart);
                long toRead = compSize;
                byte[] comp;

                if (encrypted) {
                    // 12-byte encryption header + ciphertext
                    int[] keys = initKeys(pw);
                    byte[] hdr = new byte[12];
                    raf.readFully(hdr);
                    for (int b = 0; b < 12; b++) hdr[b] = decryptByte(keys, hdr[b]);
                    // verification byte: high byte of CRC (bit-3 archives use high byte of mod time)
                    int check = ((flag & 0x8) != 0) ? -1 : (int) ((crcOf(raf, pos) >>> 24) & 0xff);
                    if (check >= 0 && (hdr[11] & 0xff) != check) r.badPassword = true;
                    long body = toRead - 12;
                    comp = new byte[(int) body];
                    raf.readFully(comp);
                    for (int b = 0; b < comp.length; b++) comp[b] = decryptByte(keys, comp[b]);
                } else {
                    comp = new byte[(int) toRead];
                    raf.readFully(comp);
                }

                try (OutputStream os = new FileOutputStream(out)) {
                    if (method == 0) {                          // stored
                        os.write(comp);
                    } else if (method == 8) {                   // deflate
                        Inflater inf = new Inflater(true);
                        inf.setInput(comp);
                        byte[] buf = new byte[65536];
                        while (!inf.finished()) {
                            int n = inf.inflate(buf);
                            if (n == 0) {
                                if (inf.needsInput() || inf.needsDictionary()) break;
                            } else {
                                os.write(buf, 0, n);
                            }
                        }
                        inf.end();
                    } else {
                        os.close();
                        out.delete();
                        r.skipped++;
                        continue;
                    }
                }
                r.files++;
                r.names.add(name);
            }
        } catch (Throwable t) {
            r.error = t.getClass().getSimpleName() + ": " + (t.getMessage() == null ? "" : t.getMessage());
        }
        return r;
    }

    // crcOf reads the central-dir CRC for the entry at central-dir position p (offset+16).
    private static long crcOf(RandomAccessFile raf, long p) throws java.io.IOException {
        long save = raf.getFilePointer();
        raf.seek(p + 16);
        long crc = readU32(raf);
        raf.seek(save);
        return crc;
    }

    // ----- ZipCrypto -----
    private static int[] initKeys(byte[] pw) {
        int[] k = {0x12345678, 0x23456789, 0x34567890};
        for (byte b : pw) updateKeys(k, b);
        return k;
    }
    private static void updateKeys(int[] k, byte c) {
        k[0] = crc32(k[0], c);
        k[1] = k[1] + (k[0] & 0xff);
        k[1] = k[1] * 134775813 + 1;
        k[2] = crc32(k[2], (byte) (k[1] >>> 24));
    }
    private static int crc32(int crc, byte b) {
        return (crc >>> 8) ^ CRC[(crc ^ b) & 0xff];
    }
    private static byte decryptByte(int[] k, byte cipher) {
        int temp = (k[2] | 2) & 0xffff;
        int plain = (cipher & 0xff) ^ (((temp * (temp ^ 1)) >>> 8) & 0xff);
        updateKeys(k, (byte) plain);
        return (byte) plain;
    }

    // ----- low-level readers (little-endian) -----
    private static int readU16(RandomAccessFile raf) throws java.io.IOException {
        int a = raf.read(), b = raf.read();
        return (a & 0xff) | ((b & 0xff) << 8);
    }
    private static long readU32(RandomAccessFile raf) throws java.io.IOException {
        long a = raf.read(), b = raf.read(), c = raf.read(), d = raf.read();
        return (a & 0xff) | ((b & 0xff) << 8) | ((c & 0xff) << 16) | ((d & 0xff) << 24);
    }
    private static long readU64(RandomAccessFile raf) throws java.io.IOException {
        long lo = readU32(raf), hi = readU32(raf);
        return lo | (hi << 32);
    }

    private static long findEOCD(RandomAccessFile raf, long len) throws java.io.IOException {
        long start = Math.max(0, len - 65557);             // max comment 65535 + 22
        raf.seek(start);
        byte[] buf = new byte[(int) (len - start)];
        raf.readFully(buf);
        for (int i = buf.length - 22; i >= 0; i--) {
            if ((buf[i] & 0xff) == 0x50 && (buf[i+1] & 0xff) == 0x4b
                    && (buf[i+2] & 0xff) == 0x05 && (buf[i+3] & 0xff) == 0x06) {
                return start + i;
            }
        }
        return -1;
    }
    private static long findZip64EOCD(RandomAccessFile raf, long eocd) throws java.io.IOException {
        // The ZIP64 EOCD locator sits 20 bytes before the EOCD.
        long locOff = eocd - 20;
        if (locOff < 0) return -1;
        raf.seek(locOff);
        if (readU32(raf) != 0x07064b50L) return -1;
        raf.seek(locOff + 8);
        long z64 = readU64(raf);
        raf.seek(z64);
        if (readU32(raf) != 0x06064b50L) return -1;
        return z64;
    }
}
