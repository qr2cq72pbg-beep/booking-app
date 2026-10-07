package com.gtwebstudio.booking;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import com.capacitorjs.plugins.pushnotifications.PushNotificationsPlugin;
import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import java.util.Map;

/**
 * Capacitor cannot display FCM when the WebView/plugin is gone.
 * If the plugin is alive, keep the existing Capacitor path.
 * If it is not, post a system notification on xbook-business-push-v1.
 */
public class XBookFirebaseMessagingService extends FirebaseMessagingService {

    static final String BUSINESS_PUSH_CHANNEL_ID = "xbook-business-push-v1";

    @Override
    public void onMessageReceived(@NonNull RemoteMessage remoteMessage) {
        super.onMessageReceived(remoteMessage);
        if (PushNotificationsPlugin.getPushNotificationsInstance() != null) {
            PushNotificationsPlugin.sendRemoteMessage(remoteMessage);
            return;
        }
        postTerminatedFallback(remoteMessage);
    }

    @Override
    public void onNewToken(@NonNull String token) {
        super.onNewToken(token);
        PushNotificationsPlugin.onNewToken(token);
    }

    private void postTerminatedFallback(RemoteMessage remoteMessage) {
        Map<String, String> data = remoteMessage.getData();
        RemoteMessage.Notification notification = remoteMessage.getNotification();

        String title = "";
        String body = "";
        if (notification != null) {
            title = safe(notification.getTitle());
            body = safe(notification.getBody());
        }
        if (title.isEmpty()) title = safe(data.get("title"));
        if (body.isEmpty()) body = safe(data.get("body"));
        if (title.isEmpty()) title = getString(R.string.app_name);

        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (manager == null) return;
        ensureBusinessChannel(manager);

        String messageId = safe(remoteMessage.getMessageId());
        if (messageId.isEmpty()) messageId = safe(data.get("event_id"));
        if (messageId.isEmpty()) messageId = "xbook-" + System.currentTimeMillis();

        Intent tapIntent = new Intent(this, MainActivity.class);
        tapIntent.addFlags(
            Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_NEW_TASK
        );
        tapIntent.putExtra("google.message_id", messageId);
        for (Map.Entry<String, String> entry : data.entrySet()) {
            if (entry.getKey() != null && entry.getValue() != null) {
                tapIntent.putExtra(entry.getKey(), entry.getValue());
            }
        }

        int notificationId = messageId.hashCode();
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this,
            notificationId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
        );

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, BUSINESS_PUSH_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_xbook)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(new NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setDefaults(NotificationCompat.DEFAULT_SOUND | NotificationCompat.DEFAULT_VIBRATE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pendingIntent);

        manager.notify(notificationId, builder.build());
    }

    private void ensureBusinessChannel(NotificationManager manager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        if (manager.getNotificationChannel(BUSINESS_PUSH_CHANNEL_ID) != null) return;
        NotificationChannel channel = new NotificationChannel(
            BUSINESS_PUSH_CHANNEL_ID,
            "Business alerts",
            NotificationManager.IMPORTANCE_HIGH
        );
        channel.setDescription("New appointments and new customers for this business");
        channel.enableVibration(true);
        manager.createNotificationChannel(channel);
    }

    private static String safe(String value) {
        return value == null ? "" : value.trim();
    }
}
