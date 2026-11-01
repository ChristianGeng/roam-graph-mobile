package io.github.christiangeng.roamgraph

import android.content.ContentResolver
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

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

    /**
     * The largest audio file taken (100 MB), and the most audio files copied
     * at once (#221). Audio is copied to the cache folder "voice", not read
     * into memory: the Dart side reads the copy when it is used.
     */
    const val MAX_AUDIO_BYTES = 100L * 1024 * 1024
    const val MAX_AUDIO_FILES = 5

    private val audioExtensions = setOf("mp3", "m4a", "aac", "mp4", "wav", "flac", "ogg", "oga", "opus", "webm", "weba")

    private val extensions = setOf("txt", "md", "markdown", "org")
    private val mimeTypes = setOf("text/plain", "text/markdown", "text/x-markdown", "text/x-org", "text/org")

    /**
     * The URIs of EXTRA_STREAM in a share intent; empty if there are none.
     * Other URIs than content:// are kept too, so that [read] names them as
     * refused; they are never opened.
     */
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

    /** True if the file is taken as audio, by its MIME type or its name (#221). */
    fun isAudio(name: String, mimeType: String?): Boolean {
        val type = mimeType?.substringBefore(';')?.trim()?.lowercase() ?: ""
        if (type.startsWith("audio/") || type == "video/webm" || type == "video/mp4") return true
        val dot = name.lastIndexOf('.')
        return dot > 0 && name.substring(dot + 1).lowercase() in audioExtensions
    }

    /**
     * Each file as a map for the Dart side: name, mimeType, and bytes (at
     * most MAX_BYTES + 1), size when it is larger, or error. Files after
     * the first MAX_FILES and files that are not text are not read.
     * Runs off the main thread: reading may be slow.
     */
    fun read(
        resolver: ContentResolver,
        voiceDir: File,
        uris: List<Uri>,
        sentType: String?,
    ): List<Map<String, Any?>> {
        clearOldVoice(voiceDir)
        var audioCount = 0
        return uris.mapIndexed { index, uri ->
            // Only content:// URIs are opened: a file:// URI would be opened
            // with the app's own rights, so a sender could make it read the
            // app's private files. The others are named with the reason.
            if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
                return@mapIndexed mapOf<String, Any?>(
                    "name" to (uri.lastPathSegment?.substringAfterLast('/') ?: uri.toString()),
                    "mimeType" to sentType,
                    "error" to "only files shared by an app (content:) are read, not ${uri.scheme ?: "this"}: links",
                )
            }
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
            val providerType = try {
                resolver.getType(uri)
            } catch (e: RuntimeException) {
                null
            }
            // A provider that only says application/octet-stream knows less
            // than a sender that says text.
            val mimeType = if (
                providerType?.substringBefore(';')?.trim()?.lowercase() == "application/octet-stream" &&
                (isText(name, sentType) || isAudio(name, sentType))
            ) {
                sentType
            } else {
                providerType ?: sentType
            }
            val file = mutableMapOf<String, Any?>("name" to name, "mimeType" to mimeType)
            val known = size
            when {
                isAudio(name, mimeType) -> {
                    // Audio is copied, up to MAX_AUDIO_FILES of it (#221).
                    if (audioCount < MAX_AUDIO_FILES) {
                        audioCount++
                        copyAudio(resolver, uri, voiceDir, audioCount, name, size, file)
                    }
                }
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
    }

    /**
     * Copies the audio at [uri] to [voiceDir], and puts its "path" and, if
     * Android can tell, its "durationMs" into [file]; a file over
     * MAX_AUDIO_BYTES is not copied and gets its "size" instead.
     */
    private fun copyAudio(
        resolver: ContentResolver,
        uri: Uri,
        voiceDir: File,
        number: Int,
        name: String,
        size: Long?,
        file: MutableMap<String, Any?>,
    ) {
        if (size != null && size > MAX_AUDIO_BYTES) {
            file["size"] = size
            return
        }
        try {
            voiceDir.mkdirs()
            val copy = File(voiceDir, "${System.currentTimeMillis()}-$number-${name.replace(Regex("[^A-Za-z0-9._-]"), "_")}")
            var total = 0L
            val input = resolver.openInputStream(uri) ?: throw IllegalStateException("the file could not be opened")
            input.use {
                FileOutputStream(copy).use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (total <= MAX_AUDIO_BYTES) {
                        val n = it.read(buffer)
                        if (n < 0) break
                        out.write(buffer, 0, n)
                        total += n
                    }
                }
            }
            if (total > MAX_AUDIO_BYTES) {
                copy.delete()
                file["size"] = total
                return
            }
            file["path"] = copy.absolutePath
            // The app's own copy, which the Dart side may delete.
            file["copy"] = true
            file["size"] = total
            durationMs(copy)?.let { file["durationMs"] = it }
        } catch (e: Exception) {
            // SecurityException, FileNotFoundException, IOException and the like.
            file["error"] = e.message ?: e.javaClass.simpleName
        }
    }

    /** The length of the audio file, or null if Android cannot tell. */
    private fun durationMs(file: File): Int? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.toInt()
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    /** Deletes copies from earlier shares that are more than a day old. */
    private fun clearOldVoice(voiceDir: File) {
        val limit = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        voiceDir.listFiles()?.forEach { if (it.lastModified() < limit) it.delete() }
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
