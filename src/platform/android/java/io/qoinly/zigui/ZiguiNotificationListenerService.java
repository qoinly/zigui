package io.qoinly.zigui;

import android.app.Notification;
import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

// zigui's shipped notification-listener shell: a system-bound NotificationListener
// Service that forwards every posted notification (package, title, text) to native
// for the app to read in Zig. The shell forwards, never decides. Unlike the
// accessibility service this one calls INTO native, so it must ensure the app's .so
// is loaded - the system may bind it before ZiguiActivity has run.
public class ZiguiNotificationListenerService extends NotificationListenerService {
    private static boolean sConnected;

    @Override
    public void onCreate() {
        super.onCreate();
        loadAppLibrary();
    }

    @Override
    public void onListenerConnected() {
        sConnected = true;
    }

    @Override
    public void onListenerDisconnected() {
        sConnected = false;
    }

    static boolean isEnabled() {
        return sConnected;
    }

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        Notification n = sbn.getNotification();
        if (n == null) {
            return;
        }
        Bundle extras = n.extras;
        nativeOnNotification(
            sbn.getPackageName(),
            charSeq(extras, Notification.EXTRA_TITLE),
            charSeq(extras, Notification.EXTRA_TEXT));
    }

    private static String charSeq(Bundle extras, String key) {
        if (extras == null) {
            return "";
        }
        CharSequence v = extras.getCharSequence(key);
        return v != null ? v.toString() : "";
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

    private native void nativeOnNotification(String pkg, String title, String text);
}
