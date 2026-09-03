package com.ai_image_gen.aiimagegen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Foreground service that downloads model files in the background.
 *
 *  - Keeps running when the app is backgrounded or the screen is off (foreground
 *    notification makes the OS treat it as an active, high-priority process).
 *  - Shows a live progress notification with a progress bar.
 *  - Supports pause / resume (Range requests) and cancel.
 *  - Persists its state to <filesDir>/downloads/<jobId>.json so Flutter can
 *    restore the UI after a restart, and broadcasts events so the running app
 *    gets real-time updates.
 */
class DownloadService : Service() {

    private val lock = Any()
    private var worker: DownloadWorker? = null
    private var jobId: String? = null
    private var label: String = "Model"
    private var destDir: String? = null
    private var files: JSONArray = JSONArray()

    override fun onCreate() {
        super.onCreate()
        DownloadService.createNotificationChannel(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        when (intent.action) {
            ACTION_START -> handleStart(intent)
            ACTION_PAUSE -> handlePause(intent)
            ACTION_RESUME -> handleResume(intent)
            ACTION_CANCEL -> handleCancel(intent)
        }
        return START_NOT_STICKY
    }

    private fun handleStart(intent: Intent) {
        val newJob = intent.getStringExtra(EXTRA_JOB_ID) ?: return
        val newDest = intent.getStringExtra(EXTRA_DEST_DIR) ?: return
        val newFiles = intent.getStringExtra(EXTRA_FILES) ?: return
        val newLabel = intent.getStringExtra(EXTRA_LABEL) ?: newJob

        synchronized(lock) {
            val active = worker
            if (active != null && active.isRunning()) {
                // A download is genuinely in progress. Ignore the duplicate
                // start quietly instead of failing the job — the UI can fire
                // a "Restart download" while the service is busy, and that
                // must not corrupt the running download's state.
                Log.d(TAG, "Download already active (${active.jobId}); ignoring duplicate start.")
                return
            }
            jobId = newJob
            label = newLabel
            destDir = newDest
            files = JSONArray(newFiles)
            startWorker()
        }
    }

    private fun handlePause(intent: Intent) {
        val target = intent.getStringExtra(EXTRA_JOB_ID)
        synchronized(lock) {
            val w = worker ?: return
            if (target != null && target != w.jobId) return
            w.pause()
            stopForegroundInternal()
            publishState(w.jobId, STATE_PAUSED, w.receivedBytes(), w.totalBytes(), w.currentFile(), "")
            stopSelf()
        }
    }

    private fun handleResume(intent: Intent) {
        val target = intent.getStringExtra(EXTRA_JOB_ID)
        synchronized(lock) {
            val active = worker
            if (active != null && active.isRunning()) return
            val dir = destDir ?: return
            val job = jobId ?: return
            if (target != null && target != job) return

            val loaded = loadState(job)
            if (loaded != null) {
                // Rebuild from the persisted job if this service was restarted.
                label = loaded.optString("label", label)
                destDir = loaded.optString("destDir", dir)
                files = loaded.optJSONArray("files") ?: files
            }
            worker = DownloadWorker(this, job, label, destDir!!, files)
            startForegroundInternal(0, 0)
            startWorker()
        }
    }

    private fun handleCancel(intent: Intent) {
        val target = intent.getStringExtra(EXTRA_JOB_ID)
        synchronized(lock) {
            val w = worker
            if (w != null) {
                if (target != null && target != w.jobId) return
                w.cancel()
            } else if (target != null) {
                deleteState(target)
                val dir = destDir
                if (dir != null) deletePartFiles(target, dir)
                publishState(target, STATE_CANCELLED, 0, 0, "", "")
            }
            stopForegroundInternal()
            stopSelf()
        }
    }

    private fun startWorker() {
        val job = jobId ?: return
        val dir = destDir ?: return
        worker = DownloadWorker(this, job, label, dir, files)
        startForegroundInternal(0, 0)
        worker!!.start()
    }

    private fun startForegroundInternal(received: Long, total: Long) {
        val id = NOTIFICATION_ID
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(id, buildProgressNotification(label, received, total, "Starting download…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(id, buildProgressNotification(label, received, total, "Starting download…"))
        }
    }

    private fun stopForegroundInternal() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        synchronized(lock) {
            worker?.requestStop()
            worker = null
        }
        super.onDestroy()
    }

    // ------------------------------------------------------------------ helpers

    private fun buildProgressNotification(model: String, received: Long, total: Long, text: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val progress: Int
        val indeterminate: Boolean
        if (total > 0) {
            val pct = ((received * 100) / total).toInt().coerceIn(0, 100)
            progress = pct
            indeterminate = false
        } else {
            progress = 0
            indeterminate = true
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Downloading $model")
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, progress, indeterminate)
        return builder.build()
    }

    fun publishState(
        job: String,
        state: String,
        received: Long,
        total: Long,
        currentFile: String,
        error: String
    ) {
        writeState(job, state, received, total, currentFile, error)
        val event = JSONObject()
            .put("jobId", job)
            .put("state", state)
            .put("received", received)
            .put("total", total)
            .put("currentFile", currentFile)
            .put("error", error)
        val broadcast = Intent(EVENT_ACTION).setPackage(packageName).putExtra("event", event.toString())
        sendBroadcast(broadcast)
    }

    private fun stateFile(job: String): File = File(filesDir, "downloads_$job.json")

    private fun writeState(job: String, state: String, received: Long, total: Long, currentFile: String, error: String) {
        val info = jobState(job, state, received, total, currentFile, error, label, destDir ?: "", files.toString())
        try {
            stateFile(job).writeText(info.toString())
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to persist state", t)
        }
    }

    private fun jobState(
        job: String, state: String, received: Long, total: Long,
        currentFile: String, error: String, label: String, destDir: String, filesJson: String
    ): JSONObject {
        return JSONObject()
            .put("jobId", job)
            .put("label", label)
            .put("state", state)
            .put("received", received)
            .put("total", total)
            .put("currentFile", currentFile)
            .put("error", error)
            .put("destDir", destDir)
            .put("files", JSONArray(filesJson))
            .put("lastUpdate", System.currentTimeMillis())
    }

    fun loadState(job: String): JSONObject? {
        return try {
            val f = stateFile(job)
            if (f.exists()) JSONObject(f.readText()) else null
        } catch (t: Throwable) {
            null
        }
    }

    private fun deleteState(job: String) {
        try {
            stateFile(job).delete()
        } catch (t: Throwable) {
            // ignore
        }
    }

    private fun deletePartFiles(job: String, dir: String) {
        try {
            File(dir).walkTopDown().forEach {
                if (it.isFile && it.name.endsWith(PART_EXT)) it.delete()
            }
        } catch (t: Throwable) {
            // ignore
        }
    }

    companion object {
        private const val TAG = "AIImageGen-DL"
        const val ACTION_START = "com.ai_image_gen.aiimagegen.DOWNLOAD_START"
        const val ACTION_PAUSE = "com.ai_image_gen.aiimagegen.DOWNLOAD_PAUSE"
        const val ACTION_RESUME = "com.ai_image_gen.aiimagegen.DOWNLOAD_RESUME"
        const val ACTION_CANCEL = "com.ai_image_gen.aiimagegen.DOWNLOAD_CANCEL"
        const val EXTRA_JOB_ID = "jobId"
        const val EXTRA_LABEL = "label"
        const val EXTRA_DEST_DIR = "destDir"
        const val EXTRA_FILES = "files"

        const val EVENT_ACTION = "com.ai_image_gen.aiimagegen.DOWNLOAD_EVENT"
        const val CHANNEL_ID = "aiimagegen_downloads"
        const val NOTIFICATION_ID = 1001
        const val PART_EXT = ".part"
        const val STATE_RUNNING = "running"
        const val STATE_PAUSED = "paused"
        const val STATE_COMPLETED = "completed"
        const val STATE_FAILED = "failed"
        const val STATE_CANCELLED = "cancelled"

        @Volatile
        private var activeJob: String? = null

        fun isActive(jobId: String?): Boolean = activeJob != null && (jobId == null || jobId == activeJob)

        fun createNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Model downloads",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Progress of Stable Diffusion model downloads"
                setShowBadge(false)
            }
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * Sequentially downloads each file of the model with Range-based resume.
     */
    private inner class DownloadWorker(
        private val context: Context,
        val jobId: String,
        private val modelLabel: String,
        private val destDir: String,
        private val files: JSONArray
    ) {
        private val thread = Thread({ runDownload() }, "download-$jobId")
        @Volatile private var running = true
        @Volatile private var paused = false
        @Volatile private var cancelled = false
        @Volatile private var currentFileName = ""
        @Volatile private var receivedAggregate = 0L
        @Volatile private var totalAggregate = 0L

        fun start() {
            activeJob = jobId
            thread.start()
        }

        fun isRunning(): Boolean = thread.isAlive && !paused && !cancelled

        fun pause() {
            paused = true
            running = false
        }

        fun cancel() {
            cancelled = true
            running = false
            // interrupt the blocking read so cancel is immediate
            thread.interrupt()
        }

        fun requestStop() {
            running = false
        }

        fun receivedBytes(): Long = receivedAggregate
        fun totalBytes(): Long = totalAggregate
        fun currentFile(): String = currentFileName

        private fun runDownload() {
            DownloadService.createNotificationChannel(context)
            var fileIndex = 0
            try {
                val filesDir = File(destDir)
                filesDir.mkdirs()

                val total = computeTotalBytes()
                totalAggregate = total

                for (i in 0 until files.length()) {
                    if (!running) break
                    val fileObj = files.getJSONObject(i)
                    val relPath = fileObj.getString("path")
                    val url = fileObj.getString("url")
                    val sizeHint = fileObj.optLong("size", -1L)
                    currentFileName = relPath
                    fileIndex = i

                    val target = File(filesDir, relPath)
                    target.parentFile?.mkdirs()
                    val part = File(target.parentFile, target.name + PART_EXT)

                    // Skip files already fully downloaded.
                    if (target.exists() && (sizeHint <= 0 || target.length() >= sizeHint - 64)) {
                        receivedAggregate += target.length()
                        updateNotification()
                        continue
                    }

                    val result = downloadFile(url, part, target, sizeHint)
                    if (!running) {
                        if (cancelled) {
                            onCancelled()
                        } else {
                            onPaused(fileIndex)
                        }
                        return
                    }
                    if (result != true) {
                        if (result == null) {
                            // permanent failure (e.g. HTTP 403/404)
                            fail("Failed to download $relPath")
                            return
                        }
                        // transient failure (timeout / truncated stream) -> retry once
                        Log.w(TAG, "Retrying $relPath")
                        val retry = downloadFile(url, part, target, sizeHint)
                        if (retry != true) {
                            fail("Failed to download $relPath")
                            return
                        }
                    }
                    receivedAggregate = computeReceivedTotal()
                    updateNotification()
                }

                if (cancelled) {
                    onCancelled()
                } else if (!running) {
                    onPaused(fileIndex)
                } else {
                    onCompleted()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Download failed", t)
                fail(t.message ?: "Download failed")
            }
        }

        /**
         * @return true on success, false on transient failure (caller retries), null on permanent failure
         */
        private fun downloadFile(url: String, part: File, target: File, sizeHint: Long): Boolean? {
            var conn: HttpURLConnection? = null
            try {
                val existing = if (part.exists()) part.length() else 0L
                if (existing > 0 && target.length() > 0) {
                    // corrupted leftover; restart this file
                    part.delete()
                }
                val start = if (part.exists()) part.length() else 0L

                conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 30_000
                conn.readTimeout = 60_000
                conn.instanceFollowRedirects = true
                conn.setRequestProperty("Accept-Encoding", "identity")
                conn.setRequestProperty("User-Agent", "AI-Image-Gen/1.0")
                if (start > 0) {
                    conn.setRequestProperty("Range", "bytes=$start-")
                }
                conn.connect()

                val code = conn.responseCode
                if (code == 404 || code == 403) {
                    return null // permanent
                }
                if (code == 200 && start > 0) {
                    // Server does not support ranges; restart the file.
                    part.delete()
                }

                val input = conn.inputStream ?: return null
                val output = FileOutputStream(part, true)
                val buffer = ByteArray(128 * 1024)
                val totalForFile = if (code == 206) {
                    start + conn.contentLengthLong
                } else if (conn.contentLengthLong > 0) {
                    conn.contentLengthLong
                } else {
                    sizeHint
                }
                var written = if (start > 0 && code != 200) start else 0L
                var lastNotify = System.currentTimeMillis()

                while (running) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    if (n == 0) continue
                    output.write(buffer, 0, n)
                    written += n
                    val now = System.currentTimeMillis()
                    if (now - lastNotify > 500) {
                        lastNotify = now
                        receivedAggregate = computeReceivedTotal()
                        updateNotification()
                    }
                }
                output.flush()
                output.close()
                input.close()
                receivedAggregate = computeReceivedTotal()

                if (!running) {
                    // paused or cancelled mid-file
                    return true // treat as handled by caller
                }
                if (totalForFile > 0 && written < totalForFile - 64) {
                    return false // truncated -> retry
                }
                if (part.exists()) {
                    if (!part.renameTo(target)) {
                        target.delete()
                        part.copyTo(target, overwrite = true)
                        part.delete()
                    }
                }
                return true
            } catch (e: InterruptedException) {
                if (cancelled) {
                    // clean up partial file for cancelled files
                    return true
                }
                return false
            } catch (t: Throwable) {
                Log.w(TAG, "downloadFile error for $url", t)
                if (t is IOException && running && !cancelled) return false
                return false
            } finally {
                try {
                    conn?.disconnect()
                } catch (_: Throwable) {
                }
            }
        }

        private fun computeTotalBytes(): Long {
            var total = 0L
            for (i in 0 until files.length()) {
                val size = files.getJSONObject(i).optLong("size", -1L)
                if (size > 0) total += size
            }
            return total
        }

        private fun computeReceivedTotal(): Long {
            var received = 0L
            val root = File(destDir)
            for (i in 0 until files.length()) {
                val f = File(root, files.getJSONObject(i).getString("path"))
                if (f.exists()) received += f.length()
                val part = File(root, files.getJSONObject(i).getString("path") + PART_EXT)
                if (part.exists()) received += part.length()
            }
            return received
        }

        private fun updateNotification() {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val received = receivedAggregate
            val total = totalAggregate
            val text = "File $currentFileName — ${formatBytes(received)} / ${if (total > 0) formatBytes(total) else "?"}"
            nm.notify(NOTIFICATION_ID, buildProgressNotification(modelLabel, received, total, text))
            publishState(jobId, STATE_RUNNING, received, total, currentFileName, "")
        }

        private fun onCompleted() {
            activeJob = null
            receivedAggregate = computeReceivedTotal()
            publishState(jobId, STATE_COMPLETED, receivedAggregate, totalAggregate, "", "")
            NotificationHelper.show(
                context,
                "$modelLabel ready",
                "The model has finished downloading.",
                id = NOTIFICATION_ID + 1
            )
            stopForegroundInternal()
            stopSelf()
        }

        private fun onPaused(fileIndex: Int) {
            activeJob = null
            val state = publishState(jobId, STATE_PAUSED, receivedAggregate, totalAggregate, currentFileName, "")
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                NOTIFICATION_ID,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("Download paused")
                    .setContentText("$modelLabel — resume from the app.")
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .build()
            )
            stopForegroundInternal()
            stopSelf()
        }

        private fun onCancelled() {
            activeJob = null
            deletePartFiles(jobId, destDir)
            publishState(jobId, STATE_CANCELLED, 0, 0, "", "")
            NotificationHelper.show(context, "Download cancelled", "$modelLabel was cancelled.", id = NOTIFICATION_ID + 1)
            stopForegroundInternal()
            stopSelf()
        }

        private fun fail(message: String) {
            activeJob = null
            publishState(jobId, STATE_FAILED, receivedAggregate, totalAggregate, currentFileName, message)
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                NOTIFICATION_ID,
                NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
                    .setContentTitle("Download failed")
                    .setContentText("$modelLabel — $message")
                    .setStyle(NotificationCompat.BigTextStyle().bigText("$modelLabel — $message"))
                    .setAutoCancel(true)
                    .build()
            )
            stopForegroundInternal()
            stopSelf()
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes <= 0) return "0 B"
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var i = 0
        while (value >= 1024 && i < units.size - 1) {
            value /= 1024.0
            i++
        }
        return String.format("%.1f %s", value, units[i])
    }
}
