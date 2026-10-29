package io.github.christiangeng.roamgraph

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * The notifications of the AI chats (#202): the ongoing one of the
 * foreground service, and one for each answer that is ready or failed.
 */
object ChatNotifications {
    const val ACTION_OPEN = "io.github.christiangeng.roamgraph.OPEN_CHAT"
    const val EXTRA_CHAT = "chatId"

    private const val CHANNEL_WORK = "chat_work"
    private const val CHANNEL_ANSWER = "chat_answer"
    const val WORK_ID = 2020
    private const val ANSWER_ID = 2021

    /**
     * True when the app may show notifications: the permission on Android 13
     * and later, and the app's switch in Android's settings on all versions.
     */
    fun allowed(context: Context): Boolean = manager(context).areNotificationsEnabled()

    private fun manager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun channels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = manager(context)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_WORK, "AI is working", NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ANSWER, "Answers", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /** A tap opens the app; [chatId] empty opens the chat list, else that chat. */
    private fun tapIntent(context: Context, chatId: String): PendingIntent {
        // The data makes the intent of each chat different for Android, which
        // compares intents without their extras: no chat's tap replaces another's.
        val open = Intent(context, MainActivity::class.java)
            .setAction(ACTION_OPEN)
            .setData(Uri.parse("roamgraph://chat/" + Uri.encode(chatId)))
            .putExtra(EXTRA_CHAT, chatId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            0,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    @Suppress("DEPRECATION")
    private fun builder(context: Context, channel: String): Notification.Builder {
        channels(context)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channel)
        } else {
            Notification.Builder(context)
        }
        return builder.setSmallIcon(R.drawable.ic_stat_chat)
    }

    /** The ongoing, low-priority notification of the service. */
    fun working(context: Context, chats: Int): Notification {
        val text = if (chats == 1) "AI is working on 1 chat" else "AI is working on $chats chats"
        return builder(context, CHANNEL_WORK)
            .setContentTitle(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(tapIntent(context, ""))
            .build()
    }

    /** An answer or a failure; one notification for each chat, a new one replaces it. */
    fun answer(context: Context, chatId: String, title: String, text: String) {
        if (!allowed(context)) return
        val notification = builder(context, CHANNEL_ANSWER)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(tapIntent(context, chatId))
            .build()
        // The chat's ID is the tag: one notification for each chat.
        manager(context).notify(chatId, ANSWER_ID, notification)
    }

    fun update(context: Context, chats: Int) {
        if (!allowed(context)) return
        manager(context).notify(WORK_ID, working(context, chats))
    }
}

/**
 * The foreground service that keeps the app's process alive while an AI chat
 * works (#202). It does no work itself: the requests run in Dart. Its type is
 * dataSync (network transfer), declared in AndroidManifest.xml.
 */
class ChatWorkService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val chats = intent?.getIntExtra(EXTRA_CHATS, 1) ?: 1
        running = true
        val notification = ChatNotifications.working(this, chats)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                ChatNotifications.WORK_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(ChatNotifications.WORK_ID, notification)
        }
        return START_NOT_STICKY
    }

    /** Android 15 limits dataSync services to six hours a day: stop in time. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val EXTRA_CHATS = "chats"

        /** True while the service runs; then the notification is updated in place. */
        @Volatile
        var running = false

        fun start(context: Context, chats: Int) {
            if (running) {
                ChatNotifications.update(context, chats)
                return
            }
            val intent = Intent(context, ChatWorkService::class.java).putExtra(EXTRA_CHATS, chats)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, ChatWorkService::class.java))
        }
    }
}
