package com.example.hdr_player

import android.media.MediaFormat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Rewrites general_level_idc in the HEVC VPS and SPS. The level is only a label in the headers, but
 * many vendor decoders refuse (or die right after start) when it is above what they advertise,
 * even when the real load fits. Verified byte-identical to ffmpeg's hevc_metadata=level=... rewrite.
 */
object HevcLevel {
    private class Nal(val startCodeLen: Int, val bytes: ByteArray)

    private fun split(b: ByteArray): List<Nal> {
        val starts = ArrayList<IntArray>() // [index, startCodeLen]
        var i = 0
        while (i + 3 <= b.size) {
            if (b[i].toInt() == 0 && b[i + 1].toInt() == 0) {
                if (b[i + 2].toInt() == 1) {
                    starts.add(intArrayOf(i, 3)); i += 3; continue
                }
                if (b[i + 2].toInt() == 0 && i + 3 < b.size && b[i + 3].toInt() == 1) {
                    starts.add(intArrayOf(i, 4)); i += 4; continue
                }
            }
            i++
        }
        val out = ArrayList<Nal>()
        for ((k, s) in starts.withIndex()) {
            val begin = s[0] + s[1]
            val end = if (k + 1 < starts.size) starts[k + 1][0] else b.size
            out.add(Nal(s[1], b.copyOfRange(begin, end)))
        }
        return out
    }

    private fun unescape(b: ByteArray, from: Int): ByteArray {
        val out = ByteArrayOutputStream(b.size)
        var zeros = 0
        for (i in from until b.size) {
            val x = b[i].toInt() and 0xff
            if (zeros >= 2 && x == 3) { zeros = 0; continue }
            out.write(x)
            zeros = if (x == 0) zeros + 1 else 0
        }
        return out.toByteArray()
    }

    private fun escape(b: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(b.size + 8)
        var zeros = 0
        for (v in b) {
            val x = v.toInt() and 0xff
            if (zeros >= 2 && x <= 3) { out.write(3); zeros = 0 }
            out.write(x)
            zeros = if (x == 0) zeros + 1 else 0
        }
        return out.toByteArray()
    }

    /** Annex-B parameter sets in, same sets with the new level out. Null if no VPS/SPS was found. */
    fun patch(annexB: ByteArray, level: Int): ByteArray? {
        var changed = false
        val out = ByteArrayOutputStream(annexB.size + 8)
        for (nal in split(annexB)) {
            var bytes = nal.bytes
            if (bytes.size > 20) {
                val type = (bytes[0].toInt() shr 1) and 0x3f
                if (type == 32 || type == 33) { // VPS / SPS
                    val rbsp = unescape(bytes, 2)
                    val idx = if (type == 32) 15 else 12 // profile_tier_level starts at byte 4 (VPS) / 1 (SPS); level is +11
                    if (rbsp.size > idx) {
                        rbsp[idx] = level.toByte()
                        bytes = bytes.copyOfRange(0, 2) + escape(rbsp)
                        changed = true
                    }
                }
            }
            out.write(if (nal.startCodeLen == 4) byteArrayOf(0, 0, 0, 1) else byteArrayOf(0, 0, 1))
            out.write(bytes)
        }
        return if (changed) out.toByteArray() else null
    }
}

/** Human-readable name of config variant [idx] from [codecConfigVariants]. */
fun variantName(idx: Int): String = when (idx) {
    0 -> "full format"
    1 -> "essentials + colour"
    2 -> "essentials only"
    3 -> "level relabelled 5.0"
    4 -> "level relabelled 4.1"
    else -> "variant $idx"
}

/**
 * Vendor decoders sometimes reject a stream's full format (frame-rate hints, profile/level,
 * colour keys) or its declared level. Try, in order: the full format, essentials + colour,
 * bare essentials, then (HEVC) bare essentials with the level relabelled to 5.0 and 4.1.
 */
fun codecConfigVariants(f: MediaFormat, mime: String): List<MediaFormat> {
    if (!mime.startsWith("video/")) return listOf(f)
    val w = f.getInteger(MediaFormat.KEY_WIDTH)
    val h = f.getInteger(MediaFormat.KEY_HEIGHT)

    fun essentials(withColor: Boolean, csd0: ByteArray? = null): MediaFormat {
        val m = MediaFormat.createVideoFormat(mime, w, h)
        for (k in listOf("csd-0", "csd-1", "csd-2")) {
            if (k == "csd-0" && csd0 != null) {
                m.setByteBuffer(k, ByteBuffer.wrap(csd0))
            } else if (f.containsKey(k)) {
                m.setByteBuffer(k, f.getByteBuffer(k)!!.duplicate())
            }
        }
        for (k in listOf(MediaFormat.KEY_MAX_INPUT_SIZE, MediaFormat.KEY_ROTATION)) {
            if (f.containsKey(k)) m.setInteger(k, f.getInteger(k))
        }
        if (withColor) {
            for (k in listOf(
                MediaFormat.KEY_COLOR_STANDARD,
                MediaFormat.KEY_COLOR_TRANSFER,
                MediaFormat.KEY_COLOR_RANGE
            )) {
                if (f.containsKey(k)) m.setInteger(k, f.getInteger(k))
            }
            if (f.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) {
                m.setByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO, f.getByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO)!!.duplicate())
            }
        }
        return m
    }

    val out = arrayListOf(f, essentials(true), essentials(false))
    if (mime.equals("video/hevc", true) && f.containsKey("csd-0")) {
        val bb = f.getByteBuffer("csd-0")!!.duplicate()
        val bytes = ByteArray(bb.remaining())
        bb.get(bytes)
        for (level in intArrayOf(150, 123)) { // 5.0, 4.1
            val patched = HevcLevel.patch(bytes, level)
            if (patched != null) out.add(essentials(true, patched))
        }
    }
    return out
}
