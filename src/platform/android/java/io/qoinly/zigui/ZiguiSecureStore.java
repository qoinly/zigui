package io.qoinly.zigui;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.KeyStore;
import java.security.SecureRandom;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

// A hardware-backed secret store: returns a stable 32-byte key for an alias, generated
// once and kept across launches. The raw key never sits in the clear on disk - it is
// sealed with an AES-GCM key held in the AndroidKeyStore (non-extractable, TEE-backed
// where present), and only the sealed blob lives in the app's private files dir. The
// native side reads this through one JNI call; a failure returns null (vars stay off).
public final class ZiguiSecureStore {
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String TRANSFORM = "AES/GCM/NoPadding";
    private static final int KEY_BYTES = 32;
    private static final int TAG_BITS = 128;

    public static byte[] getOrCreateKey(Context ctx, String alias) {
        try {
            SecretKey seal = getOrCreateSealKey("zigui-seal-" + alias);
            File file = new File(ctx.getFilesDir(), alias + ".seal");
            if (file.exists()) {
                return unseal(seal, readAll(file));
            }
            byte[] key = new byte[KEY_BYTES];
            new SecureRandom().nextBytes(key);
            writeAll(file, seal(seal, key));
            return key;
        } catch (Exception e) {
            return null;
        }
    }

    // The AndroidKeyStore AES key that seals the master key - created on first use and
    // reused thereafter, so the sealed blob stays decryptable across launches.
    private static SecretKey getOrCreateSealKey(String alias) throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE);
        ks.load(null);
        KeyStore.Entry entry = ks.getEntry(alias, null);
        if (entry instanceof KeyStore.SecretKeyEntry) {
            return ((KeyStore.SecretKeyEntry) entry).getSecretKey();
        }
        KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
        kg.init(new KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return kg.generateKey();
    }

    // [ivLen | iv | ciphertext+tag]. GCM picks a fresh random IV per seal.
    private static byte[] seal(SecretKey k, byte[] data) throws Exception {
        Cipher c = Cipher.getInstance(TRANSFORM);
        c.init(Cipher.ENCRYPT_MODE, k);
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(data);
        byte[] out = new byte[1 + iv.length + ct.length];
        out[0] = (byte) iv.length;
        System.arraycopy(iv, 0, out, 1, iv.length);
        System.arraycopy(ct, 0, out, 1 + iv.length, ct.length);
        return out;
    }

    private static byte[] unseal(SecretKey k, byte[] blob) throws Exception {
        int ivLen = blob[0] & 0xff;
        Cipher c = Cipher.getInstance(TRANSFORM);
        c.init(Cipher.DECRYPT_MODE, k, new GCMParameterSpec(TAG_BITS, blob, 1, ivLen));
        return c.doFinal(blob, 1 + ivLen, blob.length - 1 - ivLen);
    }

    private static byte[] readAll(File f) throws Exception {
        byte[] buf = new byte[(int) f.length()];
        try (FileInputStream in = new FileInputStream(f)) {
            int off = 0;
            while (off < buf.length) {
                int n = in.read(buf, off, buf.length - off);
                if (n < 0) break;
                off += n;
            }
        }
        return buf;
    }

    private static void writeAll(File f, byte[] data) throws Exception {
        try (FileOutputStream out = new FileOutputStream(f)) {
            out.write(data);
        }
    }

    private ZiguiSecureStore() {}
}
