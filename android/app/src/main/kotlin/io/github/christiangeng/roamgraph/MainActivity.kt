package io.github.christiangeng.roamgraph

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var folderAccess: FolderAccess? = null
    private var shareChannel: MethodChannel? = null

    /**
     * Text shared with the app through Android's share menu (#15), until the
     * Dart side takes it: {text, subject}. The app is a share target for
     * plain text (ACTION_SEND, text/plain, in AndroidManifest.xml).
     */
    private var pendingShare: Map<String, String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val access = FolderAccess(this)
        folderAccess = access
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FolderAccess.CHANNEL)
            .setMethodCallHandler(access)
        // Methods: takeShare() -> {text, subject} or null, once per share.
        // Calls to Dart: shareArrived(), when a share comes while running.
        val share = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        share.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeShare" -> {
                    result.success(pendingShare)
                    pendingShare = null
                }
                else -> result.notImplemented()
            }
        }
        shareChannel = share
        // A share that started the app.
        keepShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // A share while the app runs (launchMode singleTop).
        if (keepShare(intent)) shareChannel?.invokeMethod("shareArrived", null)
    }

    /** Keeps the text of a share intent; true if [intent] was one. */
    private fun keepShare(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_SEND) return false
        if (intent.type?.startsWith("text/") != true) return false
        val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return false
        pendingShare = mapOf(
            "text" to text,
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
        )
        // Handled: a recreated activity must not take it again.
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
    }
}
