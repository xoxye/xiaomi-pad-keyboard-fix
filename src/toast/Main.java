package toast;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.system.Os;
import android.widget.Toast;

public class Main {
    public static void main(String[] args) {
        if (args == null || args.length == 0 || args[0].trim().isEmpty()) {
            return;
        }
        final String text = args[0];
        try {
            // Drop UID to 1000 (system) if running as root so NotificationManagerService
            // allows package "android"
            try {
                Os.setgid(1000);
                Os.setuid(1000);
            } catch (Throwable ignored) {}

            Looper.prepare();
            Class<?> atCls = Class.forName("android.app.ActivityThread");
            Object at = atCls.getMethod("systemMain").invoke(null);
            final Context ctx = (Context) atCls.getMethod("getSystemContext").invoke(at);

            Handler h = new Handler(Looper.myLooper());
            h.post(new Runnable() {
                @Override
                public void run() {
                    try {
                        Toast toast = Toast.makeText(ctx, text, Toast.LENGTH_SHORT);
                        toast.show();
                    } catch (Throwable t) {
                        t.printStackTrace();
                    }
                }
            });
            // 300ms window allows Binder IPC enqueueTextToast to complete before process exit
            h.postDelayed(new Runnable() {
                @Override
                public void run() {
                    System.exit(0);
                }
            }, 300);
            Looper.loop();
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }
}