package io.github.christiangeng.roamgraph

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var folderAccess: FolderAccess? = null
    private var shareChannel: MethodChannel? = null
    private var chatsChannel: MethodChannel? = null

    /**
     * The chat a tap on a notification asked for (#202), until the Dart side
     * takes it: its ID, or "" for the chat list. Null when there is none.
     */
    private var pendingOpen: String? = null

    /** The answer to "requestPermission", while Android shows its question. */
    private var permissionResult: MethodChannel.Result? = null

    /**
     * Texts shared with the app through Android's share menu (#15), oldest
     * first, until the Dart side takes them, one at a time. The app is a
     * share target for plain text (ACTION_SEND, text/plain, in
     * AndroidManifest.xml). Each is a bundle with "text" and "subject".
     * They are kept in the saved state, so a share is not lost when Android
     * recreates the activity before the app took it.
     */
    private val pendingShares = ArrayDeque<Bundle>()

    /** True when Android recreated the activity from its saved state. */
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        restored = savedInstanceState != null
        savedInstanceState?.let { state ->
            pendingOpen = state.getString(KEY_OPEN)
            @Suppress("DEPRECATION")
            state.getParcelableArrayList<Bundle>(KEY_SHARES)?.let { pendingShares.addAll(it) }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putParcelableArrayList(KEY_SHARES, ArrayList(pendingShares))
        // A tap on a notification the Dart side did not take yet.
        outState.putString(KEY_OPEN, pendingOpen)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val access = FolderAccess(this)
        folderAccess = access
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FolderAccess.CHANNEL)
            .setMethodCallHandler(access)
        // Methods: takeShare() -> {text, subject} of the oldest share not
        // taken yet, or null; shareText({text, subject}) opens Android's share
        // menu to send text to another app, such as an AI app (#40). Calls to
        // Dart: shareArrived(), when a share comes while the app runs.
        val share = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        share.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeShare" -> {
                    val next = pendingShares.removeFirstOrNull()
                    result.success(
                        next?.let {
                            mapOf("text" to it.getString("text"), "subject" to it.getString("subject"))
                        },
                    )
                }
                "shareText" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("bad_args", "text is missing", null)
                    } else {
                        val send = Intent(Intent.ACTION_SEND)
                            .setType("text/plain")
                            .putExtra(Intent.EXTRA_TEXT, text)
                        call.argument<String>("subject")?.let {
                            send.putExtra(Intent.EXTRA_SUBJECT, it)
                        }
                        startActivity(Intent.createChooser(send, null))
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = share
        // keepScreenOn({on}): the screen stays on while the AI works (#131),
        // so it does not lock in the middle of a request.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCREEN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // The AI chats (#202). Methods: working({chats}) starts the
        // foreground service or updates its number; idle() stops it;
        // hasPermission() and requestPermission() for notifications (Android
        // 13 and later); notify({chatId, title, text}); takeOpen() -> the chat
        // a tap on a notification asked for ("" for the list), or null. Calls
        // to Dart: openRequested(), when a tap comes while the app runs.
        val chats = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHATS_CHANNEL)
        chats.setMethodCallHandler { call, result -> onChatsCall(call, result) }
        chatsChannel = chats
        if (!restored) keepOpen(intent)
        // A share that started the app. A recreated activity gets its
        // original intent back from Android, but that share is in the saved
        // queue already, or was taken: reading it again would repeat it.
        if (!restored) keepShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A share while the app runs (launchMode singleTop).
        if (keepShare(intent)) shareChannel?.invokeMethod("shareArrived", null)
        if (keepOpen(intent)) chatsChannel?.invokeMethod("openRequested", null)
    }

    private fun onChatsCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "working" -> {
                try {
                    ChatWorkService.start(this, call.argument<Int>("chats") ?: 1)
                    result.success(null)
                } catch (e: RuntimeException) {
                    // Android does not let the app start the service now (IllegalStateException), or the permission is missing (SecurityException).
                    result.error("service", e.message, null)
                }
            }
            "idle" -> {
                ChatWorkService.stop(this)
                result.success(null)
            }
            "hasPermission" -> result.success(ChatNotifications.answersAllowed(this))
            "requestPermission" -> {
                if (ChatNotifications.allowed(this)) {
                    result.success(true)
                } else if (permissionResult != null || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    result.success(false)
                } else {
                    permissionResult = result
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
                }
            }
            "notify" -> {
                val chatId = call.argument<String>("chatId")
                val title = call.argument<String>("title")
                if (chatId == null || title == null) {
                    result.error("bad_args", "chatId or title is missing", null)
                } else {
                    ChatNotifications.answer(this, chatId, title, call.argument<String>("text") ?: "")
                    result.success(null)
                }
            }
            "takeOpen" -> {
                result.success(pendingOpen)
                pendingOpen = null
            }
            else -> result.notImplemented()
        }
    }

    /** Remembers the chat a tap on a notification asked for; true if [intent] was one. */
    private fun keepOpen(intent: Intent?): Boolean {
        if (intent?.action != ChatNotifications.ACTION_OPEN) return false
        pendingOpen = intent.getStringExtra(ChatNotifications.EXTRA_CHAT) ?: ""
        // Taken once: a recreated activity must not open it again.
        setIntent(Intent(Intent.ACTION_MAIN))
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        permissionResult?.success(granted)
        permissionResult = null
    }

    /** Queues the text of a share intent; true if [intent] was one. */
    private fun keepShare(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_SEND) return false
        if (intent.type?.startsWith("text/") != true) return false
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return false
        pendingShares.addLast(
            Bundle().apply {
                putString("text", text)
                putString("subject", intent.getStringExtra(Intent.EXTRA_SUBJECT))
            },
        )
        // Queued: a recreated activity must not queue it again.
        setIntent(Intent(Intent.ACTION_MAIN))
        return true
    }

    @Deprecated("FlutterActivity is a plain Activity, so the picker result arrives here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (folderAccess?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        const val SHARE_CHANNEL = "roam_graph/share"
        const val SCREEN_CHANNEL = "roam_graph/screen"
        const val CHATS_CHANNEL = "roam_graph/chats"
        private const val REQUEST_NOTIFICATIONS = 4202
        private const val KEY_SHARES = "pending_shares"
        private const val KEY_OPEN = "pending_open"
    }
}
