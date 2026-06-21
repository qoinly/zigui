package io.qoinly.zigui;

import android.app.NativeActivity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.hardware.biometrics.BiometricPrompt;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.provider.OpenableColumns;
import android.telephony.SmsManager;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;

// zigui's shipped activity shell. A thin shim over NativeActivity: the superclass
// still loads the native library and runs the exported ANativeActivity_onCreate, so
// all rendering and touch stay native. This subclass exists only for the things a
// pure NativeActivity lacks - a hidden EditText that owns the IME, the back funnel,
// the document-picker result, the BiometricPrompt, and the accessibility delegators.
// Every framework callback is mirrored to native; the shell forwards, never decides.
// It is package-agnostic (loads whichever .so the manifest's android.app.lib_name
// names), so any app can declare it in its manifest and write zero Java.
public class ZiguiActivity extends NativeActivity {
    private EditText edit;

    @Override
    protected void onCreate(Bundle state) {
        loadAppLibrary();
        super.onCreate(state);
        edit = new EditText(this);
        edit.setFocusable(true);
        edit.setFocusableInTouchMode(true);
        // 1x1 so it never visibly paints over the native surface, but still has a
        // real size + a place in the hierarchy so it can take focus and raise the IME.
        addContentView(edit, new ViewGroup.LayoutParams(1, 1));
        edit.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
            public void onTextChanged(CharSequence s, int a, int b, int c) {}
            public void afterTextChanged(Editable s) {
                nativeOnText(s.toString(), edit.getSelectionStart());
            }
        });
        // Predictive back (the default for targetSdk 35+) retires onBackPressed: the
        // legacy key no longer reaches the Activity, so back must come from the
        // OnBackInvokedDispatcher instead. native pops the route stack; if it does
        // not consume the press (the root), background the app like the system would.
        // When the soft keyboard is up it owns a higher-priority callback and hides
        // first, so this only fires once the keyboard is down. onBackPressed below
        // still covers API < 33, where this dispatcher does not exist.
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                new OnBackInvokedCallback() {
                    public void onBackInvoked() {
                        if (!nativeOnBack()) {
                            moveTaskToBack(true);
                        }
                    }
                });
        }
    }

    // The JNI native methods below resolve only against libraries the ClassLoader
    // loaded; NativeActivity's own dlopen does not register with it. So load the same
    // .so the manifest's android.app.lib_name names - read from this activity's
    // meta-data rather than hardcoded, so the shell works for any app's library.
    private void loadAppLibrary() {
        try {
            ActivityInfo ai = getPackageManager().getActivityInfo(
                getComponentName(), PackageManager.GET_META_DATA);
            String lib = ai.metaData != null
                ? ai.metaData.getString("android.app.lib_name") : null;
            if (lib != null) {
                System.loadLibrary(lib);
            }
        } catch (PackageManager.NameNotFoundException e) {
            // leave it to NativeActivity; the JNI natives may then be unresolved
        }
    }

    // Called from native when a text field gains focus: seed the editor with the
    // field's current value and raise the keyboard.
    public void showKeyboard(final String initial) {
        runOnUiThread(new Runnable() {
            public void run() {
                edit.setText(initial);
                edit.setSelection(initial.length());
                edit.requestFocus();
                InputMethodManager imm =
                    (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                imm.showSoftInput(edit, 0);
            }
        });
    }

    public void hideKeyboard() {
        runOnUiThread(new Runnable() {
            public void run() {
                InputMethodManager imm =
                    (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                imm.hideSoftInputFromWindow(edit.getWindowToken(), 0);
                edit.clearFocus();
            }
        });
    }

    // The legacy back path, for API < 33 where the OnBackInvokedDispatcher above
    // does not exist. native pops the route stack; an unconsumed press falls through
    // to the default (background the app). A focused EditText makes the framework
    // pre-dispatch the Back key to the IME, so a pure NativeActivity input queue
    // never sees it - the Activity's own back handling is the reliable source.
    @Override
    public void onBackPressed() {
        if (!nativeOnBack()) {
            super.onBackPressed();
        }
    }

    // The document picker (native open_file -> startActivityForResult) returns here.
    // Matches the picker's FILE_REQUEST_CODE; the chosen content URI is not a path the
    // native side can open, so import a private copy into cacheDir and hand native the
    // display name + that copy's absolute path. A dismiss or failure cancels the pick.
    private static final int FILE_REQUEST_CODE = 0x5A16;

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != FILE_REQUEST_CODE) {
            return;
        }
        Uri uri = (res == RESULT_OK && data != null) ? data.getData() : null;
        if (uri == null) {
            nativeOnFileCancel();
            return;
        }
        String name = displayName(uri);
        String path = importToCache(uri, name);
        if (path == null) {
            nativeOnFileCancel();
            return;
        }
        nativeOnFile(name, path);
    }

    // The content URI's human display name (OpenableColumns.DISPLAY_NAME), or "file"
    // when the provider does not supply one.
    private String displayName(Uri uri) {
        String name = "file";
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (i >= 0) {
                    String v = c.getString(i);
                    if (v != null && !v.isEmpty()) {
                        name = v;
                    }
                }
            }
        } catch (Exception e) {
            // keep the fallback name
        }
        return name;
    }

    // Copy the picked content into a readable cacheDir file; returns its absolute path,
    // or null on failure. The display name may carry separators, so the leaf is
    // sanitized for the filesystem.
    private String importToCache(Uri uri, String name) {
        File out = new File(getCacheDir(), "picked-" + name.replaceAll("[^A-Za-z0-9._-]", "_"));
        try (InputStream is = getContentResolver().openInputStream(uri);
             FileOutputStream os = new FileOutputStream(out)) {
            if (is == null) {
                return null;
            }
            byte[] tmp = new byte[8192];
            int n;
            while ((n = is.read(tmp)) != -1) {
                os.write(tmp, 0, n);
            }
        } catch (Exception e) {
            return null;
        }
        return out.getAbsolutePath();
    }

    // native authenticate() calls here: build and show a BiometricPrompt on the UI
    // thread, then bridge only the two terminal outcomes (succeeded / error, which
    // covers a user cancel and a lockout) back to native as 1 / 2. A transient
    // onAuthenticationFailed (a non-matching finger) leaves the prompt up, so it is
    // not bridged. BiometricPrompt is API 28+; older devices report a failure.
    public void authenticateBiometric(final String title, final String subtitle) {
        if (Build.VERSION.SDK_INT < 28) {
            nativeOnBiometric(2);
            return;
        }
        runOnUiThread(new Runnable() {
            public void run() {
                BiometricPrompt prompt = new BiometricPrompt.Builder(ZiguiActivity.this)
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setNegativeButton("Cancel", getMainExecutor(),
                        new DialogInterface.OnClickListener() {
                            public void onClick(DialogInterface dialog, int which) {}
                        })
                    .build();
                prompt.authenticate(new CancellationSignal(), getMainExecutor(),
                    new BiometricPrompt.AuthenticationCallback() {
                        @Override
                        public void onAuthenticationSucceeded(
                                BiometricPrompt.AuthenticationResult result) {
                            nativeOnBiometric(1);
                        }
                        @Override
                        public void onAuthenticationError(int code, CharSequence msg) {
                            nativeOnBiometric(2);
                        }
                    });
            }
        });
    }

    // The optional accessibility + notification-listener services are reached by
    // native through their own static methods (FindClass on the service), so the
    // shell carries no reference to them - an app bundles a service only if it uses it.

    // Broadcast subscription: one context-registered receiver, its filter growing as
    // native subscribes actions. onReceive runs on the main thread (no Handler given),
    // so the native forward is on the same thread the kit polls from.
    private final BroadcastReceiver bcReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context ctx, Intent intent) {
            nativeOnBroadcast(intent.getAction(), ZiguiBroadcast.decode(intent));
        }
    };
    private IntentFilter bcFilter;
    private boolean bcRegistered;

    public void broadcastSubscribe(final String action) {
        runOnUiThread(new Runnable() {
            public void run() {
                if (bcFilter == null) {
                    bcFilter = new IntentFilter();
                }
                bcFilter.addAction(action);
                if (bcRegistered) {
                    unregisterReceiver(bcReceiver);
                }
                // RECEIVER_EXPORTED, not NOT_EXPORTED: some system broadcasts come
                // from a process other than system_server (SMS_RECEIVED is sent by
                // the phone process), and NOT_EXPORTED drops those. Protected system
                // broadcasts cannot be forged by other apps, so this is safe; an app
                // subscribing to a custom (non-protected) action should know other
                // apps could then trigger it.
                if (Build.VERSION.SDK_INT >= 33) {
                    registerReceiver(bcReceiver, bcFilter, Context.RECEIVER_EXPORTED);
                } else {
                    registerReceiver(bcReceiver, bcFilter);
                }
                bcRegistered = true;
            }
        });
    }

    // native sms.read() calls here: query the inbox for the most recent messages as
    // "address\tbody" lines (Cursor handling is far simpler in Java than over JNI).
    // An ungranted READ_SMS makes query throw SecurityException; that, and any other
    // failure, comes back as an empty string.
    private static final int SMS_MAX_ROWS = 20;

    public String smsRead() {
        Cursor cur;
        try {
            cur = getContentResolver().query(
                Uri.parse("content://sms/inbox"),
                new String[] {"address", "body"},
                null, null, "date DESC");
        } catch (SecurityException e) {
            return ""; // READ_SMS not granted
        }
        if (cur == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        try {
            int rows = 0;
            while (rows < SMS_MAX_ROWS && cur.moveToNext()) {
                sb.append(cur.getString(0)).append('\t')
                  .append(cur.getString(1)).append('\n');
                rows++;
            }
        } catch (Exception e) {
            return "";
        } finally {
            cur.close();
        }
        return sb.toString();
    }

    // native sms.send() calls here: hand the message to SmsManager, dividing a long
    // body into multipart parts. An ungranted SEND_SMS (or any send failure) is
    // swallowed - the native side treats send as fire-and-forget.
    public void smsSend(String address, String body) {
        SmsManager sms = Build.VERSION.SDK_INT >= 31
            ? getSystemService(SmsManager.class)
            : SmsManager.getDefault();
        if (sms == null) {
            return;
        }
        try {
            ArrayList<String> parts = sms.divideMessage(body);
            if (parts.size() > 1) {
                sms.sendMultipartTextMessage(address, null, parts, null, null);
            } else {
                sms.sendTextMessage(address, null, body, null, null);
            }
        } catch (Exception e) {
            // SEND_SMS not granted, or the send failed
        }
    }

    // Permissions. Native bridges these; the PackageManager / SharedPreferences chains
    // are far terser in Java than in JNI (the same reason the sms helpers live here).
    private static final String PERM_ASKED_PREFS = "zigui_permissions_asked";

    // The manifest's runtime permissions, "\n"-joined, so a screen drives off the
    // manifest instead of hardcoding names. Empty when none are declared.
    public String permissionsDeclared() {
        try {
            String[] ps = getPackageManager()
                .getPackageInfo(getPackageName(), PackageManager.GET_PERMISSIONS)
                .requestedPermissions;
            if (ps == null) {
                return "";
            }
            StringBuilder sb = new StringBuilder();
            for (String p : ps) {
                if (sb.length() > 0) {
                    sb.append('\n');
                }
                sb.append(p);
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    // 0 granted, 1 not-requested, 2 declined (askable), 3 declined permanently. The OS
    // reports never-asked and "don't ask again" the same way (rationale false), so an
    // asked flag persisted on request() splits the two.
    public int permissionState(String name) {
        if (checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED) {
            return 0;
        }
        if (shouldShowRequestPermissionRationale(name)) {
            return 2;
        }
        boolean asked = getSharedPreferences(PERM_ASKED_PREFS, MODE_PRIVATE)
            .getBoolean(name, false);
        return asked ? 3 : 1;
    }

    // Marks the attempt (so permissionState can later tell permanent-deny from
    // never-asked) and raises the system dialog.
    public void permissionRequest(String name) {
        getSharedPreferences(PERM_ASKED_PREFS, MODE_PRIVATE)
            .edit().putBoolean(name, true).apply();
        requestPermissions(new String[] { name }, 0);
    }

    private native void nativeOnText(String text, int caret);

    private native boolean nativeOnBack();

    private native void nativeOnFile(String name, String path);

    private native void nativeOnFileCancel();

    private native void nativeOnBiometric(int result);

    private native void nativeOnBroadcast(String action, String[] kv);
}
