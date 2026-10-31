package com.example.hdr_player

import android.media.MediaExtractor
import android.media.MediaFormat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
        return mapOf(
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
