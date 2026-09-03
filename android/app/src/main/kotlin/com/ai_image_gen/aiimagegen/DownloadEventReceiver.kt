package com.ai_image_gen.aiimagegen

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONObject

class DownloadEventReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadService.EVENT_ACTION) return
        val raw = intent.getStringExtra("event") ?: return
        try {
            MainActivity.forwardDownloadEvent(context, JSONObject(raw))
        } catch (t: Throwable) {
            Log.w("AIImageGen", "Failed to forward download event", t)
        }
    }
}
