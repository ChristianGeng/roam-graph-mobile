package io.github.christiangeng.roamgraph

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/**
 * Sharing files with other apps (#209). The Dart side has copied the files
 * into `cacheDir/share/`; here each copy gets a content URI from the
 * FileProvider declared in AndroidManifest.xml (authority
 * `<applicationId>.share`, paths in res/xml/share_paths.xml), so the
 * receiving app can read this one copy and never the notes folder.
 */
object ShareFiles {
    const val FOLDER = "share"

    /**
     * The share intent for [paths] with their [mimeTypes]: ACTION_SEND for
     * one file, ACTION_SEND_MULTIPLE for more. Throws
     * IllegalArgumentException if a path is not a file in `cacheDir/share/`.
     */
    fun intent(
        context: Context,
        paths: List<String>,
        mimeTypes: List<String>,
        text: String?,
        subject: String?,
    ): Intent {
        require(paths.isNotEmpty() && paths.size == mimeTypes.size) { "paths and mimeTypes differ" }
        val root = File(context.cacheDir, FOLDER).canonicalFile
        val uris = ArrayList<Uri>()
        for (path in paths) {
            val file = File(path).canonicalFile
            require(file.isFile && file.path.startsWith(root.path + File.separator)) {
                "not a copy in the share folder: $path"
            }
            uris.add(FileProvider.getUriForFile(context, "${context.packageName}.share", file))
        }
        val send = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
        send.type = commonType(mimeTypes)
        if (text != null) send.putExtra(Intent.EXTRA_TEXT, text)
        if (subject != null) send.putExtra(Intent.EXTRA_SUBJECT, subject)
        // The clip data lets the chooser pass the permission on to the app
        // that is picked.
        val clip = ClipData.newRawUri("share", uris[0])
        for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
        send.clipData = clip
        send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return send
    }

    /** The MIME type all of [types] share; else their main type with a wildcard; else any type. */
    fun commonType(types: List<String>): String {
        val first = types.first()
        if (types.all { it == first }) return first
        val kind = first.substringBefore('/')
        return if (types.all { it.substringBefore('/') == kind }) "$kind/*" else "*/*"
    }
}
