package io.github.christiangeng.roamgraph

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream

/**
 * Text files shared with the app (#220): ACTION_SEND or ACTION_SEND_MULTIPLE
 * with EXTRA_STREAM. Only the content: URIs are kept until the Dart side
 * takes the share; then each file is read through the content resolver.
 * The checks are those of lib/capture/text_files.dart, which checks again:
 * here they only keep large and other files from being read.
 */
object IncomingFiles {
    /** The largest file taken (1 MB); one byte more shows that it is larger. */
    const val MAX_BYTES = 1024 * 1024

    /** The most files taken at once; the others are only named. */
    const val MAX_FILES = 20

    private val extensions = setOf("txt", "md", "markdown", "org")
    private val mimeTypes = setOf("text/plain", "text/markdown", "text/x-markdown", "text/x-org", "text/org")

    /** The URIs of EXTRA_STREAM in a share intent; empty if there are none. */
    fun streams(intent: Intent): List<Uri> {
        @Suppress("DEPRECATION")
        val uris: List<Uri?> = when (intent.action) {
            Intent.ACTION_SEND -> listOf(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                },
            )
            Intent.ACTION_SEND_MULTIPLE ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                } ?: emptyList()
            else -> emptyList()
        }
        return uris.filterNotNull()
    }

    /** True if the file is taken as a text file, by its name or MIME type. */
    fun isText(name: String, mimeType: String?): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot > 0 && name.substring(dot + 1).lowercase() in extensions) return true
        return mimeType?.substringBefore(';')?.trim()?.lowercase() in mimeTypes
    }

    /**
     * Each file as a map for the Dart side: name, mimeType, and bytes (at
     * most MAX_BYTES + 1), size when it is larger, or error. Files after
     * the first MAX_FILES and files that are not text are not read.
     * Runs off the main thread: reading may be slow.
     */
    fun read(resolver: ContentResolver, uris: List<Uri>, sentType: String?): List<Map<String, Any?>> =
        uris.mapIndexed { index, uri ->
            var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
            var size: Long? = null
            try {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                        }
                    }
            } catch (e: RuntimeException) {
                // No name and size from the provider; the URI's last part is the name.
            }
            val mimeType = try {
                resolver.getType(uri)
            } catch (e: RuntimeException) {
                null
            } ?: sentType
            val file = mutableMapOf<String, Any?>("name" to name, "mimeType" to mimeType)
            val known = size
            when {
                index >= MAX_FILES || !isText(name, mimeType) -> {}
                known != null && known > MAX_BYTES -> file["size"] = known
                else -> try {
                    file["bytes"] = readAtMost(resolver, uri, MAX_BYTES + 1)
                } catch (e: Exception) {
                    // SecurityException, FileNotFoundException and the like.
                    file["error"] = e.message ?: e.javaClass.simpleName
                }
            }
            file
        }

    private fun readAtMost(resolver: ContentResolver, uri: Uri, limit: Int): ByteArray {
        val stream = resolver.openInputStream(uri) ?: throw IllegalStateException("the file could not be opened")
        stream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (out.size() < limit) {
                val n = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
                if (n < 0) break
                out.write(buffer, 0, n)
            }
            return out.toByteArray()
        }
    }
}
