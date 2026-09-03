package com.ai_image_gen.aiimagegen

import android.Manifest
import android.app.ActivityManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Debug
import android.os.Environment
import android.os.SystemClock
import android.provider.MediaStore
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "AIImageGen"
        private const val DOWNLOAD_CHANNEL = "aiimagegen/downloads"
        private const val SYSTEM_CHANNEL = "aiimagegen/system"
        private const val PERMISSION_REQUEST_CODE = 411
        private const val SAVE_PERMISSION_REQUEST_CODE = 412

        /** Album folder (under Pictures) that generated images are saved into. */
        private const val GALLERY_ALBUM = "AI Image Gen"

        @Volatile
        var latestActivity: MainActivity? = null

        @Volatile
        var downloadChannel: MethodChannel? = null

        /**
         * Deferred result of a saveImageToGallery call while the legacy
         * WRITE_EXTERNAL_STORAGE permission prompt is on screen (API < 29 only).
         */
        @Volatile
        var pendingSaveResult: MethodChannel.Result? = null

        @Volatile
        var pendingSavePath: String? = null

        /**
         * Called by [DownloadEventReceiver] when the foreground service publishes
         * a download status update. Forwards it into Dart (no-op if the app is
         * not currently running).
         */
        @JvmStatic
        fun forwardDownloadEvent(context: Context, event: JSONObject) {
            val channel = downloadChannel
            if (channel == null) {
                Log.d(TAG, "Download event dropped (Flutter engine not attached): $event")
                return
            }
            val args = mapOf(
                "jobId" to event.optString("jobId"),
                "state" to event.optString("state"),
                "received" to event.optLong("received"),
                "total" to event.optLong("total"),
                "currentFile" to event.optString("currentFile"),
                "error" to event.optString("error")
            )
            try {
                channel.invokeMethod("downloadEvent", args, object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w(TAG, "downloadEvent delivery failed: $message")
                    }
                    override fun notImplemented() {}
                })
            } catch (t: Throwable) {
                Log.w(TAG, "downloadEvent invoke failed", t)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        latestActivity = this

        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val downloads = MethodChannel(messenger, DOWNLOAD_CHANNEL)
        downloadChannel = downloads
        downloads.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        val args = call.arguments as Map<*, *>
                        val jobId = args["jobId"] as? String ?: throw IllegalArgumentException("jobId required")
                        val label = args["label"] as? String ?: jobId
                        val destDir = args["destDir"] as? String ?: throw IllegalArgumentException("destDir required")
                        val filesJson = args["filesJson"] as? String ?: throw IllegalArgumentException("files required")

                        val intent = Intent(this, DownloadService::class.java).apply {
                            action = DownloadService.ACTION_START
                            putExtra(DownloadService.EXTRA_JOB_ID, jobId)
                            putExtra(DownloadService.EXTRA_LABEL, label)
                            putExtra(DownloadService.EXTRA_DEST_DIR, destDir)
                            putExtra(DownloadService.EXTRA_FILES, filesJson)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (t: Throwable) {
                        result.error("start_failed", t.message, null)
                    }
                }
                "pause" -> {
                    val jobId = (call.arguments as? Map<*, *>)?.get("jobId") as? String ?: ""
                    startDownloadAction(DownloadService.ACTION_PAUSE, jobId)
                    result.success(true)
                }
                "resume" -> {
                    val jobId = (call.arguments as? Map<*, *>)?.get("jobId") as? String ?: ""
                    startDownloadAction(DownloadService.ACTION_RESUME, jobId)
                    result.success(true)
                }
                "cancel" -> {
                    val jobId = (call.arguments as? Map<*, *>)?.get("jobId") as? String ?: ""
                    startDownloadAction(DownloadService.ACTION_CANCEL, jobId)
                    result.success(true)
                }
                "isDownloading" -> {
                    result.success(DownloadService.isActive(jobId = (call.arguments as? Map<*, *>)?.get("jobId") as? String))
                }
                else -> result.notImplemented()
            }
        }

        val system = MethodChannel(messenger, SYSTEM_CHANNEL)
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(notificationPermissionGranted())
                }
                "notificationPermissionGranted" -> result.success(notificationPermissionGranted())
                "showNotification" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "AI Image Gen"
                    val body = args?.get("body") as? String ?: ""
                    NotificationHelper.show(this, title, body, id = (args?.get("id") as? Number)?.toInt() ?: 2000)
                    result.success(true)
                }
                "showDownloadComplete" -> {
                    val args = call.arguments as? Map<*, *>
                    val title = args?.get("title") as? String ?: "Download complete"
                    val body = args?.get("body") as? String ?: ""
                    NotificationHelper.show(this, title, body, id = (args?.get("id") as? Number)?.toInt() ?: 2001)
                    result.success(true)
                }
                "saveImageToGallery" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path") as? String
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path required", null)
                        return@setMethodCallHandler
                    }
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        pendingSavePath = path
                        pendingSaveResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            SAVE_PERMISSION_REQUEST_CODE
                        )
                    } else {
                        result.success(saveImageToGallery(path))
                    }
                }
                "shareImage" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path") as? String
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path required", null)
                        return@setMethodCallHandler
                    }
                    result.success(shareImage(path))
                }
                "getStats" -> {
                    // Live resource snapshot for the app-bar monitor. Dart
                    // samples cpuTimeNanos/wallNanos twice to compute a CPU %.
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val mi = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    result.success(
                        mapOf(
                            "appRamBytes" to appRamBytes(),
                            "cpuTimeNanos" to processCpuTimeNanos(),
                            "wallNanos" to SystemClock.elapsedRealtimeNanos(),
                            "availMem" to mi.availMem,
                            "totalMem" to mi.totalMem,
                            "lowMemory" to mi.lowMemory
                        )
                    )
                }
                "getMemoryInfo" -> {
                    // availMem/totalMem in bytes, plus a low-memory flag. Used
                    // by Dart to refuse to load a model when free RAM is
                    // insufficient (avoids being killed mid-generation).
                    val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    val mi = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    result.success(
                        mapOf(
                            "availMem" to mi.availMem,
                            "totalMem" to mi.totalMem,
                            "lowMemory" to mi.lowMemory
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != SAVE_PERMISSION_REQUEST_CODE) return
        val result = pendingSaveResult
        val path = pendingSavePath
        pendingSaveResult = null
        pendingSavePath = null
        if (result == null || path == null) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            result.success(saveImageToGallery(path))
        } else {
            result.success(null)
        }
    }

    /**
     * Opens the system share sheet with the generated image at [path] using an
     * ACTION_SEND intent backed by a FileProvider content URI (so the receiving
     * app can read the file). Returns false when the file is missing or no app
     * can handle the share.
     */
    private fun shareImage(path: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) {
                Log.w(TAG, "shareImage: source missing: $path")
                return false
            }
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(
                Intent.createChooser(intent, "Share image")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (t: Throwable) {
            Log.w(TAG, "shareImage failed", t)
            false
        }
    }

    /**
     * This process's total CPU time (user + system, all threads) in
     * nanoseconds, read from /proc/self/stat. Compared across two samples by
     * Dart to derive a CPU-usage percentage.
     */
    private fun processCpuTimeNanos(): Long {
        return try {
            val stat = File("/proc/self/stat").readText()
            val close = stat.lastIndexOf(')')
            // Fields after "pid (comm) " start at field 3 (state); utime is
            // field 14 and stime field 15 (1-indexed), i.e. indices 11/12.
            val fields = stat.substring(close + 1).trim().split(' ')
            val utime = fields.getOrNull(11)?.toLongOrNull() ?: 0L
            val stime = fields.getOrNull(12)?.toLongOrNull() ?: 0L
            val hz = Os.sysconf(OsConstants._SC_CLK_TCK)
            if (hz <= 0) 0L else (utime + stime) * 1_000_000_000L / hz
        } catch (t: Throwable) {
            Log.w(TAG, "processCpuTimeNanos failed", t)
            0L
        }
    }

    /** This process's actual RAM footprint (PSS) in bytes. */
    private fun appRamBytes(): Long {
        return try {
            val mi = Debug.MemoryInfo()
            Debug.getMemoryInfo(mi)
            mi.totalPss * 1024L // totalPss is in KB
        } catch (t: Throwable) {
            Log.w(TAG, "appRamBytes failed", t)
            0L
        }
    }

    private fun startDownloadAction(action: String, jobId: String) {
        val intent = Intent(this, DownloadService::class.java).apply {
            this.action = action
            putExtra(DownloadService.EXTRA_JOB_ID, jobId)
        }
        startService(intent)
    }

    /**
     * Copies a generated PNG into the device's public Pictures folder under an
     * album named after the app ("$GALLERY_ALBUM"), so it shows up in the
     * system gallery app. Returns the saved location (content URI on Android
     * 10+, file path before) or null when the save failed.
     */
    private fun saveImageToGallery(sourcePath: String): String? {
        return try {
            val source = File(sourcePath)
            if (!source.exists()) {
                Log.w(TAG, "saveImageToGallery: source missing: $sourcePath")
                return null
            }
            val displayName = source.name
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // MediaStore with RELATIVE_PATH needs no storage permission.
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
                    put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        "${Environment.DIRECTORY_PICTURES}/$GALLERY_ALBUM"
                    )
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
                ) ?: return null
                contentResolver.openOutputStream(uri)?.use { out ->
                    source.inputStream().use { it.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                uri.toString()
            } else {
                // Legacy: write directly into the public Pictures dir and tell
                // the MediaStore to index it.
                val dir = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_PICTURES
                    ),
                    GALLERY_ALBUM
                )
                if (!dir.exists() && !dir.mkdirs()) {
                    Log.w(TAG, "saveImageToGallery: cannot create $dir")
                    return null
                }
                val dest = File(dir, displayName)
                source.copyTo(dest, overwrite = true)
                MediaScannerConnection.scanFile(
                    this, arrayOf(dest.absolutePath), arrayOf("image/png"), null
                )
                dest.absolutePath
            }
        } catch (t: Throwable) {
            Log.w(TAG, "saveImageToGallery failed", t)
            null
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (notificationPermissionGranted()) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST_CODE
        )
    }

    private fun notificationPermissionGranted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }
}
