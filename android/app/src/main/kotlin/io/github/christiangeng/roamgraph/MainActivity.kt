package io.github.christiangeng.roamgraph

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var folderAccess: FolderAccess? = null
    private var shareChannel: MethodChannel? = null

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
            @Suppress("DEPRECATION")
            state.getParcelableArrayList<Bundle>(KEY_SHARES)?.let { pendingShares.addAll(it) }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putParcelableArrayList(KEY_SHARES, ArrayList(pendingShares))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val access = FolderAccess(this)
        folderAccess = access
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FolderAccess.CHANNEL)
            .setMethodCallHandler(access)
        // Methods: takeShare() -> {text, subject} of the oldest share not
        // taken yet, or null. Calls to Dart: shareArrived(), when a share
        // comes while the app runs.
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
                else -> result.notImplemented()
            }
        }
        shareChannel = share
        // A share that started the app. A recreated activity gets its
        // original intent back from Android, but that share is in the saved
        // queue already, or was taken: reading it again would repeat it.
        if (!restored) keepShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A share while the app runs (launchMode singleTop).
        if (keepShare(intent)) shareChannel?.invokeMethod("shareArrived", null)
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
        private const val KEY_SHARES = "pending_shares"
    }
}
