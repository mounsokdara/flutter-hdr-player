package com.example.hdr_player

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.SystemClock

/**
 * Headless decoder test: for every decoder x config on this device, decode the first frame of the
 * file into a ByteBuffer (no Surface) and report exactly which call fails. Comparing this with the
 * on-screen player tells us whether decoding or rendering is the problem.
 */
object Diagnostics {
    private fun describe(e: Throwable): String {
        val sb = StringBuilder(e.javaClass.simpleName)
        e.message?.let { sb.append(": ").append(it) }
        if (e is MediaCodec.CodecException) {
            sb.append(" [code=").append(e.errorCode).append(" recoverable=").append(e.isRecoverable)
            sb.append(" ").append(e.diagnosticInfo).append("]")
        }
        val frames = e.stackTrace.take(4).joinToString(" < ") {
            it.className.substringAfterLast('.') + "." + it.methodName + ":" + it.lineNumber
        }
        if (frames.isNotEmpty()) sb.append(" {").append(frames).append("}")
        return sb.toString()
    }

    private fun isSoftware(i: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) i.isSoftwareOnly
        else i.name.startsWith("OMX.google.") || i.name.startsWith("c2.android.")

    private fun levelName(mime: String, level: Int): String {
        if (!mime.endsWith("hevc")) return "0x" + Integer.toHexString(level)
        val names = mapOf(
            0x1 to "1", 0x4 to "2", 0x10 to "2.1", 0x40 to "3", 0x100 to "3.1", 0x400 to "4",
            0x1000 to "4.1", 0x4000 to "5", 0x10000 to "5.1", 0x40000 to "5.2",
            0x100000 to "6", 0x400000 to "6.1", 0x1000000 to "6.2"
        )
        val high = mapOf(
            0x2 to "1", 0x8 to "2", 0x20 to "2.1", 0x80 to "3", 0x200 to "3.1", 0x800 to "4",
            0x2000 to "4.1", 0x8000 to "5", 0x20000 to "5.1", 0x80000 to "5.2"
        )
        return names[level]?.let { "main-$it" } ?: high[level]?.let { "high-$it" } ?: ("0x" + Integer.toHexString(level))
    }

    fun run(path: String): String {
        val sb = StringBuilder()
        val ex = MediaExtractor()
        ex.setDataSource(path)
        var vi = -1
        for (i in 0 until ex.trackCount) {
            val m = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (m.startsWith("video/")) { vi = i; break }
        }
        if (vi < 0) { ex.release(); return "No video track in this file." }
        val f = ex.getTrackFormat(vi)
        ex.release()
        val mime = f.getString(MediaFormat.KEY_MIME) ?: return "No mime"
        val w = f.getInteger(MediaFormat.KEY_WIDTH)
        val h = f.getInteger(MediaFormat.KEY_HEIGHT)
        val fps = if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            try { f.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble() } catch (e: Exception) {
                try { f.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble() } catch (e2: Exception) { 0.0 }
            }
        } else 0.0
        sb.appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        sb.appendLine("Stream: $mime ${w}x$h @${fps}fps")
        sb.appendLine("Format: $f")

        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
        if (infos.isEmpty()) sb.appendLine("\nNo decoder on this device for $mime")
        for (info in infos) {
            sb.appendLine("\n== ${info.name} (${if (isSoftware(info)) "software" else "hardware"}) ==")
            try {
                val caps = info.getCapabilitiesForType(mime)
                sb.appendLine("profile/level: " + caps.profileLevels.joinToString { "p${it.profile}/${levelName(mime, it.level)}" })
                sb.appendLine("claims format supported: ${caps.isFormatSupported(f)}")
                val vc = caps.videoCapabilities
                if (vc != null) {
                    sb.appendLine("size ok: ${vc.isSizeSupported(w, h)}  size+rate ok: ${try { vc.areSizeAndRateSupported(w, h, if (fps > 0) fps else 30.0) } catch (e: Exception) { "?" }}")
                    sb.appendLine("frame rates for this size: ${try { vc.getSupportedFrameRatesFor(w, h) } catch (e: Exception) { "n/a" }}")
                }
            } catch (e: Exception) {
                sb.appendLine("capabilities: " + describe(e))
            }
            for ((idx, fmt) in codecConfigVariants(f, mime).withIndex()) {
                sb.appendLine(tryDecode(path, vi, info.name, fmt, idx))
            }
        }
        return sb.toString()
    }

    private fun tryDecode(path: String, vi: Int, name: String, fmt: MediaFormat, idx: Int): String {
        var stage = "extractor"
        val ex = MediaExtractor()
        var c: MediaCodec? = null
        try {
            ex.setDataSource(path)
            ex.selectTrack(vi)
            stage = "create"
            c = MediaCodec.createByCodecName(name)
            stage = "configure"
            c.configure(fmt, null, null, 0)
            stage = "start"
            c.start()
            val info = MediaCodec.BufferInfo()
            var inputs = 0
            var eos = false
            val t0 = SystemClock.elapsedRealtime()
            while (SystemClock.elapsedRealtime() - t0 < 3000) {
                if (!eos) {
                    stage = "dequeueInput"
                    val i = c.dequeueInputBuffer(5000)
                    if (i >= 0) {
                        stage = "getInputBuffer"
                        val buf = c.getInputBuffer(i)!!
                        buf.clear()
                        stage = "readSample"
                        val size = ex.readSampleData(buf, 0)
                        stage = "queueInput"
                        if (size < 0) {
                            c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            eos = true
                        } else {
                            c.queueInputBuffer(i, 0, size, ex.sampleTime, 0)
                            ex.advance()
                            inputs++
                        }
                    }
                }
                stage = "dequeueOutput"
                val o = c.dequeueOutputBuffer(info, 5000)
                if (o >= 0) {
                    stage = "releaseOutput"
                    c.releaseOutputBuffer(o, false)
                    return "#$idx (${variantName(idx)}) OK: first frame after $inputs inputs (pts ${info.presentationTimeUs} us)"
                }
            }
            return "#$idx (${variantName(idx)}) no frame within 3 s (inputs=$inputs, last call=$stage)"
        } catch (e: Exception) {
            return "#$idx (${variantName(idx)}) FAIL at $stage: ${describe(e)}"
        } finally {
            try { c?.stop() } catch (e: Exception) {}
            try { c?.release() } catch (e: Exception) {}
            try { ex.release() } catch (e: Exception) {}
        }
    }
}
