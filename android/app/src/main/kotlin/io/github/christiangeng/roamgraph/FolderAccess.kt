package io.github.christiangeng.roamgraph

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Access to the org folder through Android's Storage Access Framework (#3).
 *
 * The user picks the folder once. The app takes a persistable read
 * permission, which Android keeps across restarts, and remembers the folder
 * so it can tell "never chosen" apart from "permission lost".
 *
 * This class only picks and lists. Which files belong to the graph is
 * decided in Dart (lib/folder/org_files.dart), where it is unit-tested.
 *
 * Methods on the channel:
 * - savedFolder() -> {uri, name, hasAccess} or null if none was ever chosen
 * - pickFolder() -> {uri, name, hasAccess} or null if the user cancelled
 * - listFiles({uri, skipDirs}) -> [{path, uri, modified, size}] for every
 *   file below the folder, with paths relative to it, not entering
 *   directories whose name is in skipDirs
 */
class FolderAccess(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "roam_graph/folder"
        private const val REQUEST_PICK = 4201
        private const val PREFS = "folder_access"
        private const val KEY_URI = "tree_uri"
    }

    private val prefs get() = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainThread = Handler(Looper.getMainLooper())
    private var pendingPick: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "savedFolder" -> result.success(savedFolder())
            "pickFolder" -> pickFolder(result)
            "listFiles" -> {
                val uri = call.argument<String>("uri")
                if (uri == null) {
                    result.error("bad_args", "uri is missing", null)
                    return
                }
                val skipDirs = call.argument<List<String>>("skipDirs") ?: emptyList()
                listFiles(uri, skipDirs.toSet(), result)
            }
            else -> result.notImplemented()
        }
    }

    private fun savedFolder(): Map<String, Any>? {
        val uriString = prefs.getString(KEY_URI, null) ?: return null
        val uri = Uri.parse(uriString)
        val hasAccess = activity.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        return mapOf(
            "uri" to uriString,
            "name" to displayName(uri, hasAccess),
            "hasAccess" to hasAccess,
        )
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "The folder picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, REQUEST_PICK)
        } catch (e: Exception) {
            pendingPick = null
            result.error("no_picker", e.message, null)
        }
    }

    /** Returns true if the result was for the folder picker. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick ?: return true
        pendingPick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val resolver = activity.contentResolver
        try {
            resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            result.error("no_permission", e.message, null)
            return true
        }
        // Keep only the folder just chosen: Android limits how many
        // persisted permissions an app may hold.
        for (permission in resolver.persistedUriPermissions) {
            if (permission.uri != uri) {
                try {
                    resolver.releasePersistableUriPermission(
                        permission.uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: SecurityException) {
                    // Already gone; nothing to release.
                }
            }
        }
        prefs.edit().putString(KEY_URI, uri.toString()).apply()
        result.success(savedFolder())
        return true
    }

    private fun listFiles(uriString: String, skipDirs: Set<String>, result: MethodChannel.Result) {
        executor.execute {
            try {
                val tree = Uri.parse(uriString)
                val files = ArrayList<Map<String, Any>>()
                walk(tree, DocumentsContract.getTreeDocumentId(tree), "", skipDirs, files)
                mainThread.post { result.success(files) }
            } catch (e: Exception) {
                mainThread.post { result.error("list_failed", e.message, null) }
            }
        }
    }

    private fun walk(
        tree: Uri,
        documentId: String,
        prefix: String,
        skipDirs: Set<String>,
        out: MutableList<Map<String, Any>>,
    ) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_SIZE,
        )
        val subdirectories = ArrayList<Pair<String, String>>()
        val cursor = activity.contentResolver.query(children, columns, null, null, null)
            ?: throw IllegalStateException("Cannot read the folder $prefix")
        cursor.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1)
                if (id != null && name != null) {
                    val path = if (prefix.isEmpty()) name else "$prefix/$name"
                    if (c.getString(2) == Document.MIME_TYPE_DIR) {
                        if (name !in skipDirs) subdirectories.add(id to path)
                    } else {
                        out.add(
                            mapOf(
                                "path" to path,
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id)
                                    .toString(),
                                "modified" to (if (c.isNull(3)) 0L else c.getLong(3)),
                                "size" to (if (c.isNull(4)) 0L else c.getLong(4)),
                            ),
                        )
                    }
                }
            }
        }
        for ((id, path) in subdirectories) {
            walk(tree, id, path, skipDirs, out)
        }
    }

    /** The folder's name; without access, the last part of its tree ID. */
    private fun displayName(tree: Uri, hasAccess: Boolean): String {
        val treeId = DocumentsContract.getTreeDocumentId(tree)
        val fallback = treeId.substringAfterLast('/').substringAfterLast(':').ifEmpty { treeId }
        if (!hasAccess) return fallback
        return try {
            val document = DocumentsContract.buildDocumentUriUsingTree(tree, treeId)
            activity.contentResolver
                .query(document, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                ?: fallback
        } catch (_: Exception) {
            fallback
        }
    }
}
