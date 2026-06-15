package io.qoinly.zigui;

import android.content.Intent;
import android.os.Bundle;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import java.util.ArrayList;

// Decodes a broadcast Intent into a flat String[] of alternating key, value entries
// for native: SMS to address/body, otherwise the data URI (as "data") plus the intent
// extras stringified. A broadcast can carry many extras (ACTION_BATTERY_CHANGED has
// ~15), so this is a list, not one pair. Shared by the runtime receiver in
// ZiguiActivity and the static ZiguiBroadcastReceiver. The String[] (one element per
// value) avoids any delimiter, so a value containing tabs or newlines stays intact.
// Extraction is a primitive, not a decision - the app reacts in Zig.
final class ZiguiBroadcast {
    static String[] decode(Intent intent) {
        ArrayList<String> kv = new ArrayList<>();
        if (Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) {
            sms(intent, kv);
        } else {
            String data = intent.getDataString();
            if (data != null) {
                kv.add("data");
                kv.add(data);
            }
            extras(intent, kv);
        }
        return kv.toArray(new String[0]);
    }

    private static void sms(Intent intent, ArrayList<String> kv) {
        SmsMessage[] msgs = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (msgs == null || msgs.length == 0) {
            return;
        }
        StringBuilder body = new StringBuilder();
        for (SmsMessage m : msgs) {
            body.append(m.getMessageBody()); // concatenate a multipart message
        }
        kv.add("address");
        kv.add(String.valueOf(msgs[0].getOriginatingAddress()));
        kv.add("body");
        kv.add(body.toString());
    }

    private static void extras(Intent intent, ArrayList<String> kv) {
        Bundle extras = intent.getExtras();
        if (extras == null) {
            return;
        }
        for (String key : extras.keySet()) {
            Object v = extras.get(key);
            if (v == null) {
                continue;
            }
            kv.add(key);
            kv.add(String.valueOf(v));
        }
    }
}
