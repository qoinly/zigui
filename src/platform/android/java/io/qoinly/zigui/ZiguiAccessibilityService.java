package io.qoinly.zigui;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.graphics.Path;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.List;

// zigui's shipped accessibility service: a system-bound AccessibilityService that
// injects gestures (dispatchGesture), reads the foreground node tree, and forwards
// subscribed accessibility events to native. The native side never names this class -
// ZiguiActivity delegates to the static instance. The shell forwards primitives + the
// raw event, it does not decide; the app's event-driven logic lives in its own Zig.
// Events are opt-in (sEventMask, default 0 = forward nothing), so an idle app pays no
// per-event cost.
public class ZiguiAccessibilityService extends AccessibilityService {
    private static ZiguiAccessibilityService sInstance;
    // The OR of the AccessibilityEvent types native subscribed to; 0 forwards nothing.
    private static volatile int sEventMask;

    @Override
    public void onCreate() {
        super.onCreate();
        loadAppLibrary();
    }

    @Override
    public void onServiceConnected() {
        sInstance = this;
    }

    @Override
    public boolean onUnbind(Intent intent) {
        if (sInstance == this) {
            sInstance = null;
        }
        return super.onUnbind(intent);
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        int type = event.getEventType();
        if ((sEventMask & type) == 0) {
            return; // not subscribed - forward nothing
        }
        CharSequence pkg = event.getPackageName();
        nativeOnA11yEvent(type, pkg != null ? pkg.toString() : "", eventText(event));
    }

    @Override
    public void onInterrupt() {}

    static void subscribeEvent(int type) {
        sEventMask |= type;
    }

    private static String eventText(AccessibilityEvent event) {
        List<CharSequence> parts = event.getText();
        if (parts == null || parts.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (CharSequence cs : parts) {
            if (cs != null) {
                sb.append(cs);
            }
        }
        return sb.toString();
    }

    // The JNI native below resolves only against a ClassLoader-loaded library; if the
    // system binds this service before ZiguiActivity ran, load the app .so here too.
    // The lib name comes from this service's android.app.lib_name meta-data.
    private void loadAppLibrary() {
        try {
            ServiceInfo si = getPackageManager().getServiceInfo(
                new ComponentName(this, getClass()), PackageManager.GET_META_DATA);
            String lib = si.metaData != null ? si.metaData.getString("android.app.lib_name") : null;
            if (lib != null) {
                System.loadLibrary(lib);
            }
        } catch (PackageManager.NameNotFoundException e) {
            // the activity's own load may still cover it
        }
    }

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

    private native void nativeOnA11yEvent(int type, String pkg, String text);
}
