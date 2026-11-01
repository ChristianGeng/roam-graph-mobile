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
    private const val VOICE_ID = 2022
    const val WHAT_VOICE = "voice"

    /**
     * True when the app may show notifications: the permission on Android 13
     * and later, and the app's switch in Android's settings on all versions.
     */
    fun allowed(context: Context): Boolean = manager(context).areNotificationsEnabled()

    /** [allowed], and the channel of the answers is not switched off in Android's settings. */
    fun answersAllowed(context: Context): Boolean {
        if (!allowed(context)) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        channels(context)
        val channel = manager(context).getNotificationChannel(CHANNEL_ANSWER)
        return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
    }

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

    /** A tap opens the app where it was, with no chat (#221). */
    private fun appIntent(context: Context): PendingIntent {
        val open = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            1,
            open,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    /** A voice memo's text is ready, or its transcription failed (#221). */
    fun voice(context: Context, title: String, text: String) {
        if (!answersAllowed(context)) return
        val notification = builder(context, CHANNEL_ANSWER)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(appIntent(context))
            .build()
        manager(context).notify(VOICE_ID, notification)
    }

    /** The ongoing, low-priority notification of the service. */
    fun working(context: Context): Notification {
        val chats = WorkCounts.chats
        val voice = WorkCounts.voice > 0
        val chatText = if (chats == 1) "1 chat" else "$chats chats"
        val text = when {
            chats > 0 && voice -> "AI is working on $chatText and a voice memo"
            voice -> "Transcribing a voice memo"
            else -> "AI is working on $chatText"
        }
        return builder(context, CHANNEL_WORK)
            .setContentTitle(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(if (chats == 0) appIntent(context) else tapIntent(context, ""))
            .build()
    }

    /** An answer or a failure; one notification for each chat, a new one replaces it. */
    fun answer(context: Context, chatId: String, title: String, text: String) {
        if (!answersAllowed(context)) return
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

    fun update(context: Context) {
        if (!allowed(context)) return
        manager(context).notify(WORK_ID, working(context))
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
        running = true
        val notification = ChatNotifications.working(this)
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

        /** True while the service runs; then the notification is updated in place. */
        @Volatile
        var running = false

        /**
         * Work of one kind ([what] is "voice" for a voice memo, else AI chats)
         * runs: [count] chats, or a memo. The service runs while any kind works.
         */
        fun start(context: Context, count: Int, what: String? = null) {
            WorkCounts.set(what, count)
            if (running) {
                ChatNotifications.update(context)
                return
            }
            val intent = Intent(context, ChatWorkService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** The work of one kind ended; the service stops when none is left. */
        fun finish(context: Context, what: String? = null) {
            WorkCounts.set(what, 0)
            if (WorkCounts.chats == 0 && WorkCounts.voice == 0) {
                stop(context)
            } else if (running) {
                ChatNotifications.update(context)
            }
        }

        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, ChatWorkService::class.java))
        }
    }
}

/** What works now, by kind, so the service stops only when both are done (#221). */
object WorkCounts {
    @Volatile
    var chats = 0

    @Volatile
    var voice = 0

    fun set(what: String?, count: Int) {
        if (what == ChatNotifications.WHAT_VOICE) voice = count else chats = count
    }
}
