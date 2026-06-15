package io.qoinly.zigui;

import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;

// zigui's shipped static broadcast receiver: declared in the app's manifest, so the
// system delivers a matching broadcast even when the app is not running - cold-starting
// the process if needed. It loads the app .so and forwards the action + decoded payload
// to native, where zigui hands the app's on_background_event a decoded event. Package-
// agnostic (loads whichever .so android.app.lib_name names), so any app declares it in
// its manifest and writes zero Java. The shell forwards, never decides.
public class ZiguiBroadcastReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        loadAppLibrary(context);
        try {
            nativeOnBroadcast(intent.getAction(), ZiguiBroadcast.decode(intent));
        } catch (UnsatisfiedLinkError e) {
            // the .so failed to load on this cold start; nothing more to do headless
        }
    }

    // The same self-load the services use, via the receiver's own meta-data, since the
    // process may be cold-started for this broadcast before any Activity ran.
    private void loadAppLibrary(Context context) {
        try {
            ActivityInfo ri = context.getPackageManager().getReceiverInfo(
                new ComponentName(context, getClass()), PackageManager.GET_META_DATA);
            String lib = ri.metaData != null ? ri.metaData.getString("android.app.lib_name") : null;
            if (lib != null) {
                System.loadLibrary(lib);
            }
        } catch (PackageManager.NameNotFoundException e) {
            // no meta-data to load from; the native call below will no-op
        }
    }

    private static native void nativeOnBroadcast(String action, String[] kv);
}
