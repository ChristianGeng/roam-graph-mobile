package io.github.christiangeng.roamgraph

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Access to the org folder through Android's Storage Access Framework (#3).
 *
 * The user picks the folder once. The app takes a persistable read and
 * write permission (write since v2 capture, #11), which Android keeps
 * across restarts, and remembers the folder so it can tell "never chosen"
 * apart from "permission lost". A folder chosen before v2 has read access
 * only, until it is chosen again.
 *
 * This class only picks and lists. Which files belong to the graph is
 * decided in Dart (lib/folder/org_files.dart), where it is unit-tested.
 *
 * Methods on the channel:
 * - savedFolder() -> {uri, name, hasAccess, canWrite} or null if none was
 *   ever chosen
 * - pickFolder() -> {uri, name, hasAccess, canWrite} or null if the user
 *   cancelled
 * - listFiles({uri, skipDirs}) -> [{path, uri, directory, modified, size}]
 *   for every file and directory below the folder, with paths relative to
 *   it, leaving out (and not entering) directories named in skipDirs
 * - readFiles({uris}) -> [bytes or null] for each URI, read on the scan
 *   thread; null if a file cannot be read
 * - openWith({uri, package}) -> true if the app [package] was started to
 *   show the file (ACTION_VIEW), false if it is not installed (#10). It
 *   gets read access to the file only: v1 is read-only (decision 28).
 * - createFile({dir, name, bytes}) -> the new file's URI, in the folder
 *   [dir] (a document URI from listFiles, or the tree URI for the chosen
 *   folder itself). It never replaces a file: error "exists" if [name] is
 *   taken. The bytes go to a temporary file named as Syncthing names its
 *   own (.syncthing.NAME.tmp), which Syncthing does not sync, and the
 *   finished file is renamed into place (#13).
 * - replaceFile({dir, name, uri, expected, bytes}) -> the file's URI after
 *   replacing the file [uri], named [name] in the folder [dir], with
 *   [bytes] (#35). Only if the file is still the version the app read: its
 *   SHA-256 must be [expected] (hex), checked just before writing, else
 *   error "changed". The bytes go to a temporary file first; then the old
 *   file is renamed aside, the new one renamed into place, and the old one
 *   deleted. If a step fails, the old file is put back. Errors: "changed",
 *   "missing" (the file is gone), "write_failed".
 * - deleteFile({uri, expected}) -> true when the file [uri] was deleted
 *   (#82: undoing a note the AI created). Only if it is still the version
 *   the app wrote: its SHA-256 must be [expected], else error "changed".
 *   Errors: "changed", "missing", "write_failed".
 * - openUrl({url}) -> true if an app was started to show [url]
 *   (ACTION_VIEW), false if none can (#108). Only http, https, mailto and
 *   tel; other schemes return false without asking Android.
 */
class FolderAccess(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "roam_graph/folder"
        private const val REQUEST_PICK = 4201
        private const val PREFS = "folder_access"
        private const val KEY_URI = "tree_uri"

        // One scan thread for the whole process, shared by every instance,
        // so a recreated activity does not leave idle threads behind.
        private val executor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "roam-graph-folder-scan").apply { isDaemon = true }
        }
        private val mainThread = Handler(Looper.getMainLooper())
    }

    private val prefs get() = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
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
            "readFiles" -> {
                val uris = call.argument<List<String>>("uris")
                if (uris == null) {
                    result.error("bad_args", "uris is missing", null)
                    return
                }
                readFiles(uris, result)
            }
            "createFile" -> {
                val dir = call.argument<String>("dir")
                val name = call.argument<String>("name")
                val bytes = call.argument<ByteArray>("bytes")
                if (dir == null || name == null || bytes == null) {
                    result.error("bad_args", "dir, name or bytes is missing", null)
                    return
                }
                createFile(Uri.parse(dir), name, bytes, result)
            }
            "replaceFile" -> {
                val dir = call.argument<String>("dir")
                val name = call.argument<String>("name")
                val uri = call.argument<String>("uri")
                val expected = call.argument<String>("expected")
                val bytes = call.argument<ByteArray>("bytes")
                if (dir == null || name == null || uri == null || expected == null || bytes == null) {
                    result.error("bad_args", "dir, name, uri, expected or bytes is missing", null)
                    return
                }
                replaceFile(Uri.parse(dir), name, Uri.parse(uri), expected, bytes, result)
            }
            "deleteFile" -> {
                val uri = call.argument<String>("uri")
                val expected = call.argument<String>("expected")
                if (uri == null || expected == null) {
                    result.error("bad_args", "uri or expected is missing", null)
                    return
                }
                deleteFile(Uri.parse(uri), expected, result)
            }
            "openWith" -> {
                val uri = call.argument<String>("uri")
                val packageName = call.argument<String>("package")
                if (uri == null || packageName == null) {
                    result.error("bad_args", "uri or package is missing", null)
                    return
                }
                result.success(openWith(Uri.parse(uri), packageName))
            }
            "openUrl" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "url is missing", null)
                    return
                }
                result.success(openUrl(Uri.parse(url)))
            }
            else -> result.notImplemented()
        }
    }

    private fun openUrl(uri: Uri): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme !in setOf("http", "https", "mailto", "tel")) return false
        val intent = Intent(Intent.ACTION_VIEW, uri)
        // As a browser opens a web link: only apps that accept links.
        if (scheme == "http" || scheme == "https") {
            intent.addCategory(Intent.CATEGORY_BROWSABLE)
        }
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun savedFolder(): Map<String, Any>? {
        val uriString = prefs.getString(KEY_URI, null) ?: return null
        val uri = Uri.parse(uriString)
        val permissions = activity.contentResolver.persistedUriPermissions
        val hasAccess = permissions.any { it.uri == uri && it.isReadPermission }
        val canWrite = permissions.any { it.uri == uri && it.isWritePermission }
        return mapOf(
            "uri" to uriString,
            "name" to displayName(uri, hasAccess),
            "hasAccess" to hasAccess,
            "canWrite" to canWrite,
        )
    }

    private fun openWith(uri: Uri, packageName: String): Boolean {
        val resolver = activity.contentResolver
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, resolver.getType(uri) ?: "text/plain")
            .setPackage(packageName)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "The folder picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
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

    /**
     * Returns true if the result was for the folder picker.
     *
     * If Android recreated the activity while the picker was open, the Dart
     * call that opened it is gone (no pending result). The choice is still
     * taken and saved; the Dart side reads it with savedFolder() when the
     * app resumes.
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        val result = pendingPick
        pendingPick = null

        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return true
        }
        val resolver = activity.contentResolver
        val heldBefore = resolver.persistedUriPermissions.any { it.uri == uri }
        val readWrite =
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            resolver.takePersistableUriPermission(uri, readWrite)
        } catch (_: SecurityException) {
            // A folder that can only be read: browsing still works.
            try {
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: SecurityException) {
                result?.error("no_permission", e.message, null)
                return true
            }
        }
        // Save the new folder durably before releasing the old one, so the
        // saved folder never points at a released permission. If saving
        // fails, keep the old folder and give back the new permission.
        if (!prefs.edit().putString(KEY_URI, uri.toString()).commit()) {
            if (!heldBefore) {
                for (permission in resolver.persistedUriPermissions) {
                    if (permission.uri == uri) release(permission)
                }
            }
            result?.error("save_failed", "Could not save the chosen folder. Try again.", null)
            return true
        }
        // Keep only the folder just chosen: Android limits how many
        // persisted permissions an app may hold.
        for (permission in resolver.persistedUriPermissions) {
            if (permission.uri != uri) release(permission)
        }
        result?.success(savedFolder())
        return true
    }

    /** Gives back [permission], with exactly the modes it has. */
    private fun release(permission: android.content.UriPermission) {
        var flags = 0
        if (permission.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (permission.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            activity.contentResolver.releasePersistableUriPermission(permission.uri, flags)
        } catch (_: SecurityException) {
            // Already gone; nothing to release.
        }
    }

    private fun createFile(dir: Uri, name: String, bytes: ByteArray, result: MethodChannel.Result) {
        executor.execute {
            val outcome: Pair<String?, String?> = try {
                Pair(writeNewFile(dir, name, bytes), null)
            } catch (e: FileExistsException) {
                Pair(null, "exists")
            } catch (e: Exception) {
                Pair(null, e.message ?: e.toString())
            }
            mainThread.post {
                when (val error = outcome.second) {
                    null -> result.success(outcome.first)
                    "exists" -> result.error("exists", "$name exists already", null)
                    else -> result.error("write_failed", error, null)
                }
            }
        }
    }

    private class FileExistsException : Exception()

    /** The document URI of [dir], which may be the tree URI itself. */
    private fun documentUri(dir: Uri): Uri =
        if (DocumentsContract.isDocumentUri(activity, dir)) {
            dir
        } else {
            DocumentsContract.buildDocumentUriUsingTree(dir, DocumentsContract.getTreeDocumentId(dir))
        }

    private fun childNames(parent: Uri): Set<String> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            parent,
            DocumentsContract.getDocumentId(parent),
        )
        val names = mutableSetOf<String>()
        activity.contentResolver.query(
            children,
            arrayOf(Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) names.add(cursor.getString(0))
        }
        return names
    }

    /** Writes [bytes] as the new file [name] in [dir]; see createFile. */
    private fun writeNewFile(dir: Uri, name: String, bytes: ByteArray): String {
        val resolver = activity.contentResolver
        val parent = documentUri(dir)
        if (name in childNames(parent)) throw FileExistsException()
        val tempName = ".syncthing.$name.tmp"
        val temp = DocumentsContract.createDocument(
            resolver,
            parent,
            "application/octet-stream",
            tempName,
        ) ?: throw IllegalStateException("Could not create $tempName")
        try {
            resolver.openOutputStream(temp, "w")?.use { it.write(bytes) }
                ?: throw IllegalStateException("Could not write $tempName")
            if (name in childNames(parent)) throw FileExistsException()
            val renamed = DocumentsContract.renameDocument(resolver, temp, name)
                ?: throw IllegalStateException("Could not rename $tempName")
            // A provider may change the name, for example to "name (1)".
            val finalName = resolver.query(
                renamed,
                arrayOf(Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { if (it.moveToFirst()) it.getString(0) else null }
            if (finalName != name) {
                DocumentsContract.deleteDocument(resolver, renamed)
                throw FileExistsException()
            }
            return renamed.toString()
        } catch (e: Exception) {
            try {
                DocumentsContract.deleteDocument(resolver, temp)
            } catch (_: Exception) {
                // Already renamed or gone.
            }
            throw e
        }
    }

    private class ChangedException : Exception()
    private class MissingException : Exception()

    private fun replaceFile(
        dir: Uri,
        name: String,
        file: Uri,
        expected: String,
        bytes: ByteArray,
        result: MethodChannel.Result,
    ) {
        executor.execute {
            val outcome: Pair<String?, Pair<String, String>?> = try {
                Pair(writeReplacement(dir, name, file, expected, bytes), null)
            } catch (e: ChangedException) {
                Pair(null, Pair("changed", "$name changed since it was read"))
            } catch (e: MissingException) {
                Pair(null, Pair("missing", "$name is gone"))
            } catch (e: Exception) {
                Pair(null, Pair("write_failed", e.message ?: e.toString()))
            }
            mainThread.post {
                val error = outcome.second
                if (error == null) result.success(outcome.first) else result.error(error.first, error.second, null)
            }
        }
    }

    private fun deleteFile(file: Uri, expected: String, result: MethodChannel.Result) {
        executor.execute {
            val error: Pair<String, String>? = try {
                if (currentHash(file) != expected) {
                    Pair("changed", "The file changed since the app wrote it")
                } else if (!DocumentsContract.deleteDocument(activity.contentResolver, file)) {
                    Pair("write_failed", "The file could not be deleted")
                } else {
                    null
                }
            } catch (e: MissingException) {
                Pair("missing", "The file is gone")
            } catch (e: Exception) {
                Pair("write_failed", e.message ?: e.toString())
            }
            mainThread.post {
                if (error == null) result.success(true) else result.error(error.first, error.second, null)
            }
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** The SHA-256 of [file], or MissingException if it cannot be read. */
    private fun currentHash(file: Uri): String {
        val current = try {
            activity.contentResolver.openInputStream(file)?.use { it.readBytes() }
        } catch (_: Exception) {
            null
        } ?: throw MissingException()
        return sha256(current)
    }

    private fun displayName(doc: Uri): String? =
        activity.contentResolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }

    /** The child [name] of [parent], or null if there is none. */
    private fun child(parent: Uri, name: String): Uri? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(parent, DocumentsContract.getDocumentId(parent))
        activity.contentResolver.query(
            children,
            arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(parent, cursor.getString(0))
                }
            }
        }
        return null
    }

    /** Renames [doc] to [name]; the new URI, or null unless it has exactly
     *  that name afterwards. A provider may give "name (1)" instead; then
     *  the document is renamed back to its old name, so no stray copy is
     *  left for Syncthing to sync. */
    private fun renameExactly(doc: Uri, name: String): Uri? {
        val oldName = displayName(doc)
        val renamed = try {
            DocumentsContract.renameDocument(activity.contentResolver, doc, name)
        } catch (_: Exception) {
            null
        } ?: return null
        if (displayName(renamed) == name) return renamed
        if (oldName != null) {
            try {
                DocumentsContract.renameDocument(activity.contentResolver, renamed, oldName)
            } catch (_: Exception) {
                // Left under the provider's name; the error says where.
            }
        }
        return null
    }

    /** Replaces [file] with [bytes]; see replaceFile. */
    private fun writeReplacement(dir: Uri, name: String, file: Uri, expected: String, bytes: ByteArray): String {
        val resolver = activity.contentResolver
        val parent = documentUri(dir)
        // Both names start with ".syncthing." and end with ".tmp", so
        // Syncthing treats them as temporary files and never syncs them.
        val tempName = ".syncthing.$name.edit.tmp"
        val asideName = ".syncthing.$name.old.tmp"
        // An old copy left by an earlier attempt may be the only copy of
        // the note: never delete it; ask for it to be looked at.
        if (child(parent, asideName) != null) {
            throw IllegalStateException(
                "An earlier save left the old text of $name as $asideName. Check the folder on the laptop, then delete that file."
            )
        }
        if (currentHash(file) != expected) throw ChangedException()
        // A leftover new text holds nothing that is not saved elsewhere.
        child(parent, tempName)?.let { DocumentsContract.deleteDocument(resolver, it) }
        val temp = DocumentsContract.createDocument(resolver, parent, "application/octet-stream", tempName)
            ?: throw IllegalStateException("Could not create $tempName")
        if (displayName(temp) != tempName) {
            DocumentsContract.deleteDocument(resolver, temp)
            throw IllegalStateException("Could not create $tempName")
        }
        try {
            resolver.openOutputStream(temp, "w")?.use { it.write(bytes) }
                ?: throw IllegalStateException("Could not write $tempName")
            // Checked again just before the old file is moved: the laptop
            // may have changed it while the new text was being written.
            if (currentHash(file) != expected) throw ChangedException()
        } catch (e: Exception) {
            DocumentsContract.deleteDocument(resolver, temp)
            throw e
        }
        val aside = renameExactly(file, asideName)
        if (aside == null) {
            // The old file may or may not have moved; leave it and drop
            // the new text.
            DocumentsContract.deleteDocument(resolver, temp)
            if (child(parent, name) == null) {
                throw IllegalStateException("Could not move $name aside; its old text may be in $asideName.")
            }
            throw IllegalStateException("Could not move $name aside; nothing was changed.")
        }
        val placed = renameExactly(temp, name)
        if (placed != null) {
            try {
                DocumentsContract.deleteDocument(resolver, aside)
            } catch (_: Exception) {
                // The new file is in place. The old copy stays under its
                // temporary name, and the next save asks about it.
            }
            return placed.toString()
        }
        // The new text did not take the name. Drop it, wherever it went,
        // and put the old file back, but only onto a free name.
        child(parent, tempName)?.let { DocumentsContract.deleteDocument(resolver, it) }
        val taken = child(parent, name)
        if (taken != null) {
            throw IllegalStateException(
                "Could not save $name. Another file took its name; the old text is in $asideName."
            )
        }
        if (renameExactly(aside, name) == null) {
            throw IllegalStateException("Could not save $name, nor put it back; the old text is in $asideName.")
        }
        throw IllegalStateException("Could not save $name; it is unchanged.")
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

    private fun readFiles(uris: List<String>, result: MethodChannel.Result) {
        executor.execute {
            val resolver = activity.contentResolver
            val texts = uris.map { uri ->
                try {
                    resolver.openInputStream(Uri.parse(uri))?.use { it.readBytes() }
                } catch (_: Exception) {
                    null
                }
            }
            mainThread.post { result.success(texts) }
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
                    val isDirectory = c.getString(2) == Document.MIME_TYPE_DIR
                    if (!(isDirectory && name in skipDirs)) {
                        out.add(
                            mapOf(
                                "path" to path,
                                "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id)
                                    .toString(),
                                "directory" to isDirectory,
                                "modified" to (if (c.isNull(3)) 0L else c.getLong(3)),
                                "size" to (if (c.isNull(4)) 0L else c.getLong(4)),
                            ),
                        )
                        if (isDirectory) subdirectories.add(id to path)
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
