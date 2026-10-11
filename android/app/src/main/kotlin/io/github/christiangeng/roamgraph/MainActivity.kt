package io.github.christiangeng.roamgraph

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var folderAccess: FolderAccess? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val access = FolderAccess(this)
        folderAccess = access
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FolderAccess.CHANNEL)
            .setMethodCallHandler(access)
    }

    @Deprecated("FlutterActivity is a plain Activity, so the picker result arrives here.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (folderAccess?.onActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
