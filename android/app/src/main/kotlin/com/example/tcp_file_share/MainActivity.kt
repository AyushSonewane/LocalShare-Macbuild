package com.example.tcp_file_share

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        // ── Channel names ──────────────────────────────────────────────────────
        private const val FILE_PICKER_CHANNEL  = "com.example.tcp_file_share/file_picker"
        private const val SHARE_INTENT_CHANNEL = "com.example.tcp_file_share/share_intent"
        private const val SHARE_EVENTS_CHANNEL = "com.example.tcp_file_share/share_events"

        private const val PICK_FILES_CODE = 0x1001
    }

    // ── File-picker state ──────────────────────────────────────────────────────
    private var pendingPickResult: MethodChannel.Result? = null

    // ── Share-intent state ─────────────────────────────────────────────────────
    /** Files received before Flutter is ready (cold-start). */
    private var pendingShareFiles: List<Map<String, Any>> = emptyList()

    /** EventChannel sink — non-null once Flutter subscribes. */
    private var shareEventSink: EventChannel.EventSink? = null

    // ── FlutterEngine setup ────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── (1) File picker channel ────────────────────────────────────────────
        // Uses startActivityForResult + ACTION_OPEN_DOCUMENT — zero cache copy,
        // stable on all Android versions (avoids registerForActivityResult bugs).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> {
                        pendingPickResult?.error("ALREADY_ACTIVE", "File picker already open", null)
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }
                        try {
                            @Suppress("DEPRECATION")
                            startActivityForResult(intent, PICK_FILES_CODE)
                        } catch (e: Exception) {
                            pendingPickResult = null
                            result.error("UNAVAILABLE", "Cannot open picker: ${e.message}", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // ── (2) Share-intent method channel ────────────────────────────────────
        // Dart calls getInitialShareFiles() once at startup to drain any
        // cold-start share intent (app launched via the share sheet).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_INTENT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShareFiles" -> {
                        result.success(pendingShareFiles)
                        pendingShareFiles = emptyList()
                    }
                    else -> result.notImplemented()
                }
            }

        // ── (3) Share-events channel ───────────────────────────────────────────
        // Used for warm-start shares (app already running when the share arrives).
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    shareEventSink = sink
                    // Drain any files queued before Flutter subscribed.
                    if (pendingShareFiles.isNotEmpty()) {
                        sink.success(pendingShareFiles)
                        pendingShareFiles = emptyList()
                    }
                }
                override fun onCancel(args: Any?) {
                    shareEventSink = null
                }
            })
    }

    // ── Activity lifecycle ─────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold-start: app opened by the share sheet.
        intent?.let { handleShareIntent(it, coldStart = true) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start: another share arrives while app is already running.
        handleShareIntent(intent, coldStart = false)
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode != PICK_FILES_CODE) return
        val result = pendingPickResult ?: return
        pendingPickResult = null

        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }

        // Collect all selected URIs (single or multi-select).
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } ?: data.data?.let { uris.add(it) }

        result.success(uris.toFileMaps())
    }

    // ── Share-intent handling ─────────────────────────────────────────────────

    /**
     * Extracts content:// URIs from an Android share intent without copying
     * the file to the app cache directory.
     *
     * @param coldStart true  → Flutter not ready yet; store for later retrieval.
     *                  false → Flutter is live; push via EventChannel immediately.
     */
    private fun handleShareIntent(intent: Intent, coldStart: Boolean) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return

        val uris = mutableListOf<Uri>()
        @Suppress("DEPRECATION")
        when (action) {
            Intent.ACTION_SEND ->
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?.let { uris.addAll(it) }
        }

        val files = uris.toFileMaps()
        if (files.isEmpty()) return

        if (coldStart) {
            // Store; Flutter will call getInitialShareFiles() when ready.
            pendingShareFiles = files
        } else {
            val sink = shareEventSink
            if (sink != null) {
                sink.success(files)  // Push immediately to active stream
            } else {
                pendingShareFiles = files  // Queued until stream is subscribed
            }
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Converts a list of content URIs to [{uri, name, size}] maps. */
    private fun List<Uri>.toFileMaps(): List<Map<String, Any>> =
        mapNotNull { uri ->
            try {
                mapOf(
                    "uri"  to uri.toString(),
                    "name" to getDisplayName(uri),
                    "size" to getFileSize(uri),
                )
            } catch (_: Exception) { null }
        }

    /** Queries ContentResolver for the human-readable file name. */
    private fun getDisplayName(uri: Uri): String {
        contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME),
            null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) cursor.getString(idx)?.let { return it }
            }
        }
        return try { Uri.decode(uri.lastPathSegment ?: "file") } catch (_: Exception) { "file" }
    }

    /** Queries ContentResolver for the file size in bytes. */
    private fun getFileSize(uri: Uri): Long {
        contentResolver.query(
            uri, arrayOf(OpenableColumns.SIZE),
            null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (idx >= 0 && !cursor.isNull(idx)) return cursor.getLong(idx)
            }
        }
        return 0L
    }
}
