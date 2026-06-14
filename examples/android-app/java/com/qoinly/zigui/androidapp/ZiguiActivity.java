package com.qoinly.zigui.androidapp;

import android.app.NativeActivity;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.hardware.biometrics.BiometricPrompt;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;

// A thin shim over NativeActivity. The superclass still loads the native library
// (android.app.lib_name) and runs the exported ANativeActivity_onCreate, so all
// rendering and touch stay native. This subclass exists only to host a hidden,
// focusable EditText that owns an InputConnection - the one thing a pure
// NativeActivity lacks, and the only way the soft keyboard (IME) can deliver text
// without parsing key events. The EditText is the editing source of truth; every
// change is mirrored to native (nativeOnText) for the kit to draw.
public class ZiguiActivity extends NativeActivity {
    // NativeActivity dlopens the library for its own native code, but JNI native
    // methods (nativeOnText) resolve only against libraries the ClassLoader
    // loaded - so load it here too, otherwise nativeOnText is "not found".
    static {
        System.loadLibrary("zigui_android_app");
    }

    private EditText edit;

    @Override
    protected void onCreate(Bundle state) {
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

    // The document picker (native pick_file -> startActivityForResult) returns here.
    // Matches native_apis FILE_REQUEST_CODE; read the chosen file's text off the
    // content URI and hand it to native, which exposes it through take_picked_file.
    private static final int FILE_REQUEST_CODE = 0x5A16;

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        super.onActivityResult(req, res, data);
        if (req != FILE_REQUEST_CODE || res != RESULT_OK || data == null) {
            return;
        }
        Uri uri = data.getData();
        if (uri == null) {
            return;
        }
        String content;
        try (InputStream is = getContentResolver().openInputStream(uri)) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] tmp = new byte[4096];
            int n;
            while ((n = is.read(tmp)) != -1) {
                bos.write(tmp, 0, n);
            }
            content = new String(bos.toByteArray(), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return;
        }
        nativeOnFile(content);
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

    // Accessibility bridge: native reaches the system-bound service through these
    // delegators, so the library names only the activity (the showKeyboard pattern),
    // never the service's package.
    public boolean a11yEnabled() {
        return ZiguiAccessibilityService.isEnabled();
    }

    public void a11yTap(float x, float y) {
        ZiguiAccessibilityService.injectTap(x, y);
    }

    public void a11ySwipe(float x1, float y1, float x2, float y2, int durationMs) {
        ZiguiAccessibilityService.injectSwipe(x1, y1, x2, y2, durationMs);
    }

    public void a11yGlobalAction(int action) {
        ZiguiAccessibilityService.globalAction(action);
    }

    public String a11yReadScreen() {
        return ZiguiAccessibilityService.readScreen();
    }

    private native void nativeOnText(String text, int caret);

    private native boolean nativeOnBack();

    private native void nativeOnFile(String content);

    private native void nativeOnBiometric(int result);
}
