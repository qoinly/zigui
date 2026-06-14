package com.qoinly.zigui.androidapp;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;

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

    private native void nativeOnText(String text, int caret);
}
