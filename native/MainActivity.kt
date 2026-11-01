package com.example.hdr_player

import android.media.MediaExtractor
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaCodecList
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.media.MediaFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    companion object {
        var bgChannel: MethodChannel? = null

        /** Notification / media-session button -> Dart. */
        fun emitMedia(action: String, positionMs: Long? = null) {
            Handler(Looper.getMainLooper()).post {
                bgChannel?.invokeMethod("media", mapOf("action" to action, "positionMs" to positionMs))
            }
        }
    }

    private fun num(a: Map<*, *>, k: String): Number = (a[k] as? Number) ?: 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bgChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bg_playback").also { ch ->
            ch.setMethodCallHandler { call, result ->
                val a = (call.arguments as? Map<*, *>) ?: emptyMap<String, Any>()
                when (call.method) {
                    "start" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 77)
                        val i = Intent(this, PlaybackService::class.java)
                            .putExtra("title", a["title"] as? String ?: "Playing")
                            .putExtra("playing", a["playing"] as? Boolean ?: true)
                            .putExtra("positionMs", num(a, "positionMs").toLong())
                            .putExtra("durationMs", num(a, "durationMs").toLong())
                            .putExtra("speed", num(a, "speed").toFloat().let { if (it <= 0f) 1f else it })
                        startForegroundService(i)
                        result.success(null)
                    }
                    "update" -> {
                        PlaybackService.instance?.update(
                            a["title"] as? String,
                            a["playing"] as? Boolean ?: true,
                            num(a, "positionMs").toLong(),
                            num(a, "durationMs").toLong(),
                            num(a, "speed").toFloat().let { if (it <= 0f) 1f else it },
                        )
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, PlaybackService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hdr_probe")
            .setMethodCallHandler { call, result ->
                if (call.method == "probe") {
                    try {
                        result.success(probe(call.argument<String>("path")!!))
                    } catch (e: Exception) {
                        result.error("PROBE", e.message, null)
                    }
                } else result.notImplemented()
            }
    }

    private fun probe(path: String): Map<String, Any?> {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                return describe(f, mime)
            }
            throw IllegalStateException("No video track")
        } finally {
            ex.release()
        }
    }

    private fun intOrNull(f: MediaFormat, k: String): Int? =
        if (f.containsKey(k)) f.getInteger(k) else null

    private fun describe(f: MediaFormat, mime: String): Map<String, Any?> {
        val profile = intOrNull(f, MediaFormat.KEY_PROFILE)
        var maxLum = 0.0; var maxCll = 0.0; var maxFall = 0.0
        if (f.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) {
            val b = f.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)!!.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            // CTA-861.3 static metadata type 1 descriptor
            if (b.limit() >= 25 && b.get(0).toInt() == 0) {
                maxLum = (b.getShort(17).toInt() and 0xFFFF).toDouble()
                maxCll = (b.getShort(21).toInt() and 0xFFFF).toDouble()
                maxFall = (b.getShort(23).toInt() and 0xFFFF).toDouble()
            }
        }
        val w = intOrNull(f, MediaFormat.KEY_WIDTH) ?: 0
        val h = intOrNull(f, MediaFormat.KEY_HEIGHT) ?: 0
        val fps = frameRate(f)
        val dec = decoderCheck(mime, w, h, fps)
        return mapOf(
            "frameRate" to fps,
            "decoderSupported" to dec.first,
            "decoderMaxFps" to dec.second,
            "decoderName" to dec.third,
            "mime" to mime,
            "width" to (intOrNull(f, MediaFormat.KEY_WIDTH) ?: 0),
            "height" to (intOrNull(f, MediaFormat.KEY_HEIGHT) ?: 0),
            "colorStandard" to intOrNull(f, MediaFormat.KEY_COLOR_STANDARD),
            "colorTransfer" to intOrNull(f, MediaFormat.KEY_COLOR_TRANSFER),
            "colorRange" to intOrNull(f, MediaFormat.KEY_COLOR_RANGE),
            "profile" to profile,
            "bitDepth" to bitDepth(mime, profile),
            "maxLuminance" to maxLum,
            "maxCll" to maxCll,
            "maxFall" to maxFall,
        )
    }

    private fun frameRate(f: MediaFormat): Double {
        if (!f.containsKey(MediaFormat.KEY_FRAME_RATE)) return 0.0
        return try { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() }
        catch (e: Exception) { try { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() } catch (e2: Exception) { 0.0 } }
    }

    // Does any hardware decoder on this device accept size + frame rate?
    private fun decoderCheck(mime: String, w: Int, h: Int, fps: Double): Triple<Boolean, Double, String> {
        var best = 0.0
        var name = ""
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (info.isEncoder || !info.supportedTypes.any { it.equals(mime, true) }) continue
            val vc = info.getCapabilitiesForType(mime).videoCapabilities ?: continue
            try {
                val maxFps = vc.getSupportedFrameRatesFor(w, h).upper
                if (maxFps > best) { best = maxFps; name = info.name }
                if (fps <= 0 || vc.areSizeAndRateSupported(w, h, fps)) return Triple(true, maxFps, info.name)
            } catch (e: Exception) { /* size unsupported by this codec */ }
        }
        return Triple(false, best, name)
    }

    // Derive bit depth from codec profile (MediaExtractor doesn't expose it directly).
    private fun bitDepth(mime: String, p: Int?): Int {
        if (mime.contains("dolby-vision")) return 10
        if (p == null) return 8
        return when {
            mime.endsWith("hevc") || mime.endsWith("av01") ->
                if (p == 2 || p == 4096 || p == 8192 || p == 0x4000) 10 else 8
            mime.endsWith("vp9") -> if (p == 4 || p == 8 || p == 4096 || p == 8192 || p == 16384) 10 else 8
            mime.endsWith("avc") -> if (p == 16 || p == 32 || p == 64) 10 else 8
            else -> 8
        }
    }
}
