package com.qoinly.zigui.androidapp;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Path;
import android.graphics.Rect;
import android.os.Build;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

// The remote-control surface: a system-bound AccessibilityService that injects
// gestures (dispatchGesture) and reads the foreground node tree. The native side
// never names this class - ZiguiActivity delegates to the static instance, keeping
// the package out of the library (the showKeyboard pattern). The service holds no
// state beyond the singleton; every call no-ops when it is not connected.
public class ZiguiAccessibilityService extends AccessibilityService {
    private static ZiguiAccessibilityService sInstance;

    // A cross-app demo trigger: while a foreign app is foreground this process has no
    // tappable zigui surface, so `adb shell am broadcast -a <DEMO_ACTION>` injects a
    // swipe into whatever is on screen and logs its node tree - the remote-command
    // shape a controller (Remora) would drive. Not part of the library.
    private static final String DEMO_ACTION = "com.qoinly.zigui.androidapp.A11Y_DEMO";
    private final BroadcastReceiver demoReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            injectSwipe(160, 470, 160, 180, 250);
            Log.i("zigui-a11y", "read foreground:\n" + readScreen());
        }
    };

    @Override
    public void onServiceConnected() {
        sInstance = this;
        IntentFilter filter = new IntentFilter(DEMO_ACTION);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(demoReceiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            registerReceiver(demoReceiver, filter);
        }
    }

    @Override
    public boolean onUnbind(Intent intent) {
        if (sInstance == this) {
            sInstance = null;
        }
        try {
            unregisterReceiver(demoReceiver);
        } catch (IllegalArgumentException e) {
            // already unregistered
        }
        return super.onUnbind(intent);
    }

    // Required overrides; this service drives output and pulls content on demand, so
    // it reacts to no live events.
    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {}

    @Override
    public void onInterrupt() {}

    static boolean isEnabled() {
        return sInstance != null;
    }

    // A single-point tap: a 1ms press at (x, y) in screen pixels.
    static void injectTap(float x, float y) {
        ZiguiAccessibilityService s = sInstance;
        if (s == null) {
            return;
        }
        Path p = new Path();
        p.moveTo(x, y);
        GestureDescription g = new GestureDescription.Builder()
            .addStroke(new GestureDescription.StrokeDescription(p, 0, 1))
            .build();
        s.dispatchGesture(g, null, null);
    }

    // A swipe from (x1, y1) to (x2, y2) over durationMs (clamped to >= 1ms).
    static void injectSwipe(float x1, float y1, float x2, float y2, int durationMs) {
        ZiguiAccessibilityService s = sInstance;
        if (s == null) {
            return;
        }
        Path p = new Path();
        p.moveTo(x1, y1);
        p.lineTo(x2, y2);
        long d = durationMs <= 0 ? 1 : durationMs;
        GestureDescription g = new GestureDescription.Builder()
            .addStroke(new GestureDescription.StrokeDescription(p, 0, d))
            .build();
        s.dispatchGesture(g, null, null);
    }

    // performGlobalAction: 1 BACK, 2 HOME, 3 RECENTS (the GLOBAL_ACTION_* codes).
    static void globalAction(int action) {
        ZiguiAccessibilityService s = sInstance;
        if (s != null) {
            s.performGlobalAction(action);
        }
    }

    // Serializes the foreground window's node tree: one "left,top,width,height\ttext"
    // line per node that carries text, depth-first. Bounded by node count and depth
    // so a pathological tree cannot overrun.
    static String readScreen() {
        ZiguiAccessibilityService s = sInstance;
        if (s == null) {
            return "";
        }
        AccessibilityNodeInfo root = s.getRootInActiveWindow();
        if (root == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        walk(root, sb, 0, new int[] {0});
        return sb.toString();
    }

    private static final int MAX_NODES = 200;
    private static final int MAX_DEPTH = 40;

    private static void walk(AccessibilityNodeInfo node, StringBuilder sb, int depth, int[] count) {
        if (node == null || count[0] >= MAX_NODES || depth > MAX_DEPTH) {
            return;
        }
        CharSequence text = node.getText();
        if (text == null) {
            text = node.getContentDescription();
        }
        if (text != null && text.length() > 0) {
            Rect r = new Rect();
            node.getBoundsInScreen(r);
            sb.append(r.left).append(',').append(r.top).append(',')
              .append(r.width()).append(',').append(r.height()).append('\t')
              .append(text).append('\n');
            count[0]++;
        }
        int n = node.getChildCount();
        for (int i = 0; i < n; i++) {
            walk(node.getChild(i), sb, depth + 1, count);
        }
    }
}
