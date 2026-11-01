package com.example.hdr_player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.max

object PlayerHolder {
    @Volatile
    var player: NativePlayer? = null
}

/**
 * Our own playback engine. No third-party player code:
 *   MediaExtractor (demux)  ->  MediaCodec (decode)  ->  Surface / AudioTrack (output)
 *
 * Everything runs on one player thread, so there is no locking. Video renders straight to a
 * SurfaceView (the system compositor does HDR / tone mapping). Audio goes to an AudioTrack, which
 * is also the master clock; AudioTrack.PlaybackParams gives independent speed and pitch.
 */
class NativePlayer(ctx: Context, private val sink: (Map<String, Any?>) -> Unit) {
    private val thread = HandlerThread("native-player").also { it.start() }
    private val h = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private val audioManager = ctx.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var released = false
    private var opened = false

    // ---- media ----
    private var vEx: MediaExtractor? = null
    private var aEx: MediaExtractor? = null
    private var vFormat: MediaFormat? = null
    private var aFormat: MediaFormat? = null
    private var vCodec: MediaCodec? = null
    private var aCodec: MediaCodec? = null
    private var durationUs = 0L

    @Volatile
    private var surface: Surface? = null

    // ---- transport ----
    private var playing = false
    private var atEnd = false
    private var speed = 1f
    private var pitch = 1f
    private var pausedUs = 0L
    private var anchorUs = 0L
    private var anchorNs = 0L

    // ---- seek ----
    private var skipBeforeUs = Long.MIN_VALUE
    private var needFirstFrame = true
    private var seekDone: (() -> Unit)? = null
    private var seekStartNs = 0L

    // ---- video pipeline ----
    private val vInfo = MediaCodec.BufferInfo()
    private var vInEos = false
    private var vOutDone = false
    private var pendingV = -1
    private var pendingVPts = 0L
    private var pendingVFlags = 0
    private var lastRenderNs = 0L

    // ---- audio pipeline ----
    private val aInfo = MediaCodec.BufferInfo()
    private var aInEos = false
    private var aOutDone = false
    private var pendingA = -1
    private var pendingAOff = 0
    private var pendingARemain = 0
    private var pendingAPts = 0L
    private var pendingAFlags = 0
    private var track: AudioTrack? = null
    private var sampleRate = 48000
    private var bytesPerFrame = 4
    private var audioBaseSet = false
    private var audioBaseUs = 0L
    private var headBase = 0L
    private var audioStarted = false
    private var writtenSinceFlush = 0L
    private val ts = AudioTimestamp()

    private var lastEmitNs = 0L
    private var focus: AudioFocusRequest? = null
    private var decoderName = ""
    private val badDecoders = HashSet<String>()
    private val decoderLog = StringBuilder()
    private var videoDisabled = false
    private var audioDisabled = false

    init {
        h.post(object : Runnable {
            override fun run() {
                if (released) return
                var busy = false
                try {
                    busy = tick()
                } catch (e: Exception) {
                    fail(e)
                }
                h.postDelayed(this, if (busy) 2L else 10L)
            }
        })
    }

    // =====================================================================================
    // Public API (any thread)
    // =====================================================================================

    fun open(path: String, done: (Map<String, Any?>?, String?) -> Unit) {
        h.post {
            try {
                teardown()
                val info = doOpen(path)
                main.post { done(info, null) }
            } catch (e: Exception) {
                teardown()
                val msg = describe(e)
                main.post { done(null, msg) }
            }
        }
    }

    fun play() { h.post { doPlay() } }

    fun pause() { h.post { doPause() } }

    /** done() is called after the first frame following the seek is on screen (or on timeout). */
    fun seek(positionUs: Long, accurate: Boolean, done: () -> Unit) {
        h.post {
            finishSeek() // a newer seek supersedes the older one
            seekDone = { main.post { done() } }
            if (!opened) {
                finishSeek()
            } else {
                val max = if (durationUs > 0) durationUs else Long.MAX_VALUE
                doSeek(positionUs.coerceIn(0L, max), accurate)
            }
        }
    }

    fun setSpeed(v: Float) {
        h.post {
            val c = if (opened) clockUs() else 0L
            anchorUs = c
            anchorNs = System.nanoTime()
            speed = v
            applyParams()
        }
    }

    fun setPitch(v: Float) {
        h.post {
            pitch = v
            applyParams()
        }
    }

    fun setSurface(s: Surface?) { h.post { surface = s } }

    /** Called from the SurfaceView on surfaceDestroyed: the codec must let go before we return. */
    fun detachSurfaceBlocking() {
        val latch = CountDownLatch(1)
        h.post {
            try {
                dropVideoCodec()
            } finally {
                surface = null
                latch.countDown()
            }
        }
        latch.await(600, TimeUnit.MILLISECONDS)
    }

    fun release() {
        h.post {
            released = true
            teardown()
            thread.quitSafely()
        }
    }

    // =====================================================================================
    // Open / teardown
    // =====================================================================================

    /** Class, message, codec error details and the first frame in our own code. */
    private fun describe(e: Throwable): String {
        val sb = StringBuilder(e.javaClass.simpleName)
        e.message?.let { sb.append(": ").append(it) }
        if (e is MediaCodec.CodecException) {
            sb.append(" [code=").append(e.errorCode).append(" recoverable=").append(e.isRecoverable)
            e.diagnosticInfo.let { d -> sb.append(" ").append(d) }
            sb.append("]")
        }
        e.stackTrace.firstOrNull { it.className.startsWith("com.example") }?.let {
            sb.append(" @").append(it.fileName).append(":").append(it.lineNumber)
        }
        return sb.toString()
    }

    private inline fun quiet(block: () -> Unit) {
        try {
            block()
        } catch (ignored: Exception) {
        }
    }

    private fun MediaFormat.durationUs(): Long =
        if (containsKey(MediaFormat.KEY_DURATION)) getLong(MediaFormat.KEY_DURATION) else 0L

    private fun doOpen(path: String): Map<String, Any?> {
        val ex = MediaExtractor()
        ex.setDataSource(path)
        var vi = -1
        var ai = -1
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (vi < 0 && mime.startsWith("video/")) vi = i
            else if (ai < 0 && mime.startsWith("audio/")) ai = i
        }
        if (vi < 0 && ai < 0) {
            ex.release()
            throw IllegalStateException("No playable audio or video track")
        }
        if (vi >= 0) {
            ex.selectTrack(vi)
            vEx = ex
            vFormat = ex.getTrackFormat(vi)
        } else {
            ex.release()
        }
        if (ai >= 0) {
            val ex2 = MediaExtractor()
            ex2.setDataSource(path)
            ex2.selectTrack(ai)
            aEx = ex2
            aFormat = ex2.getTrackFormat(ai)
            aCodec = createDecoder(aFormat!!, null)
        }

        durationUs = max(vFormat?.durationUs() ?: 0L, aFormat?.durationUs() ?: 0L)
        badDecoders.clear(); decoderLog.setLength(0); videoDisabled = false; audioDisabled = false
        playing = false
        atEnd = false
        pausedUs = 0L
        anchorUs = 0L
        anchorNs = System.nanoTime()
        skipBeforeUs = Long.MIN_VALUE
        needFirstFrame = vFormat != null
        vInEos = false; vOutDone = false; pendingV = -1
        aInEos = false; aOutDone = false; pendingA = -1
        audioBaseSet = false; audioStarted = false; writtenSinceFlush = 0
        opened = true

        val vf = vFormat
        var w = 0
        var hgt = 0
        if (vf != null) {
            w = if (vf.containsKey(MediaFormat.KEY_WIDTH)) vf.getInteger(MediaFormat.KEY_WIDTH) else 0
            hgt = if (vf.containsKey(MediaFormat.KEY_HEIGHT)) vf.getInteger(MediaFormat.KEY_HEIGHT) else 0
            val rot = if (vf.containsKey(MediaFormat.KEY_ROTATION)) vf.getInteger(MediaFormat.KEY_ROTATION) else 0
            if (rot == 90 || rot == 270) {
                val t = w; w = hgt; hgt = t
            }
        }
        return mapOf(
            "durationMs" to durationUs / 1000,
            "width" to w,
            "height" to hgt,
            "hasVideo" to (vf != null),
            "hasAudio" to (aFormat != null),
        )
    }

    private fun teardown() {
        opened = false
        playing = false
        atEnd = false
        dropVideoCodec()
        aCodec?.let { c ->
            quiet { c.stop() }
            quiet { c.release() }
        }
        aCodec = null
        track?.let { t ->
            quiet { t.pause(); t.flush() }
            quiet { t.release() }
        }
        track = null
        quiet { vEx?.release() }
        quiet { aEx?.release() }
        vEx = null; aEx = null; vFormat = null; aFormat = null
        pendingA = -1; pendingV = -1
        audioBaseSet = false; audioStarted = false
        finishSeek()
        abandonFocus()
    }

    private fun dropVideoCodec() {
        vCodec?.let { c ->
            quiet { c.stop() }
            quiet { c.release() }
        }
        vCodec = null
        pendingV = -1
    }

    // =====================================================================================
    // Decoder selection: hardware first, then software, no third-party fallback needed
    // =====================================================================================

    private fun isSoftware(i: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) i.isSoftwareOnly
        else i.name.startsWith("OMX.google.") || i.name.startsWith("c2.android.")

    /**
     * Vendor decoders sometimes reject a stream's full format (frame-rate hints, profile/level,
     * colour keys) with an opaque configure error. Try: the full format, then only the
     * essentials plus colour/HDR keys, then only the bare essentials.
     */
    private fun configVariants(f: MediaFormat, mime: String): List<MediaFormat> {
        if (!mime.startsWith("video/")) return listOf(f)
        val w = f.getInteger(MediaFormat.KEY_WIDTH)
        val h = f.getInteger(MediaFormat.KEY_HEIGHT)
        fun essentials(withColor: Boolean): MediaFormat {
            val m = MediaFormat.createVideoFormat(mime, w, h)
            for (k in listOf("csd-0", "csd-1", "csd-2")) {
                if (f.containsKey(k)) m.setByteBuffer(k, f.getByteBuffer(k)!!.duplicate())
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
        return listOf(f, essentials(true), essentials(false))
    }

    private var decoderKey = ""
    private var decoderNote = ""

    private fun createDecoder(f: MediaFormat, s: Surface?): MediaCodec {
        val mime = f.getString(MediaFormat.KEY_MIME) ?: throw IllegalStateException("No mime")
        val candidates = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
            .sortedBy { info ->
                val claims = try {
                    info.getCapabilitiesForType(mime).isFormatSupported(f)
                } catch (ignored: Exception) {
                    false
                }
                (if (isSoftware(info)) 2 else 0) + (if (claims) 0 else 1)
            }
        val fails = StringBuilder()
        for (info in candidates) {
            val variants = configVariants(f, mime)
            for ((idx, fmt) in variants.withIndex()) {
                val key = "${info.name}#$idx"
                if (key in badDecoders) continue
                var c: MediaCodec? = null
                try {
                    c = MediaCodec.createByCodecName(info.name)
                    c.configure(fmt, s, null, 0)
                    c.start()
                    decoderName = info.name
                    decoderKey = key
                    decoderNote = if (idx == 0) "" else " (relaxed config $idx)"
                    return c
                } catch (e: Exception) {
                    fails.append("\n").append(key).append(": ").append(describe(e))
                    quiet { c?.release() }
                }
            }
        }
        throw IllegalStateException("No decoder could start $mime$fails")
    }

    private fun ensureVideoCodec() {
        if (videoDisabled) return
        val f = vFormat ?: return
        val s = surface ?: return
        if (vCodec != null || !s.isValid) return
        val at = if (playing) clockUs() else pausedUs
        try {
            vCodec = createDecoder(f, s)
        } catch (e: Exception) {
            disableVideo(e)
            return
        }
        emit(mapOf("type" to "decoder", "name" to decoderName + decoderNote))
        quiet { vEx?.seekTo(at, MediaExtractor.SEEK_TO_PREVIOUS_SYNC) }
        skipBeforeUs = at
        vInEos = false; vOutDone = false; pendingV = -1
        needFirstFrame = true
        seekStartNs = System.nanoTime()
    }

    /** A decoder died mid-stream: remember it and let ensureVideoCodec() pick the next candidate. */
    private fun onVideoError(e: Exception) {
        val name = decoderKey
        decoderLog.append(name).append(" (runtime): ").append(describe(e)).append('\n')
        badDecoders.add(decoderKey)
        dropVideoCodec()
        emit(mapOf("type" to "error", "message" to "Decoder $name failed while decoding (${describe(e)}), trying the next one"))
    }

    /** No decoder works: keep going audio-only instead of dying. */
    private fun disableVideo(e: Exception) {
        videoDisabled = true
        needFirstFrame = false
        finishSeek()
        val log = if (decoderLog.isNotEmpty()) "\n" + decoderLog.toString().trim() else ""
        emit(mapOf("type" to "error", "message" to "No working video decoder: ${describe(e)}$log"))
    }

    private fun onAudioError(e: Exception) {
        val now = clockUs()
        audioDisabled = true
        aCodec?.let { c ->
            quiet { c.stop() }
            quiet { c.release() }
        }
        aCodec = null
        track?.let { t ->
            quiet { t.pause() }
            quiet { t.release() }
        }
        track = null
        audioStarted = false
        anchorUs = now
        anchorNs = System.nanoTime()
        emit(mapOf("type" to "error", "message" to "Audio disabled: ${describe(e)}"))
    }

    // =====================================================================================
    // Transport
    // =====================================================================================

    private fun doPlay() {
        if (!opened || playing) return
        if (atEnd) doSeek(0L, true)
        playing = true
        anchorUs = pausedUs
        anchorNs = System.nanoTime()
        requestFocus()
        emitState()
    }

    private fun doPause() {
        if (!playing) return
        pausedUs = clockUs()
        playing = false
        quiet { track?.pause() }
        audioStarted = false
        emitState()
    }

    private fun doSeek(t: Long, accurate: Boolean) {
        atEnd = false
        pausedUs = t
        skipBeforeUs = if (accurate) t else Long.MIN_VALUE
        quiet {
            vEx?.seekTo(t, if (accurate) MediaExtractor.SEEK_TO_PREVIOUS_SYNC else MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        }
        quiet { aEx?.seekTo(t, MediaExtractor.SEEK_TO_CLOSEST_SYNC) }
        quiet { vCodec?.flush() }
        pendingV = -1; vInEos = false; vOutDone = false
        quiet { aCodec?.flush() }
        pendingA = -1; aInEos = false; aOutDone = false
        quiet {
            track?.pause()
            track?.flush()
        }
        audioBaseSet = false; audioStarted = false; writtenSinceFlush = 0
        needFirstFrame = vFormat != null
        anchorUs = t
        anchorNs = System.nanoTime()
        seekStartNs = System.nanoTime()
        if (vFormat == null) finishSeek()
        emitState()
    }

    private fun finishSeek() {
        val cb = seekDone
        seekDone = null
        cb?.invoke()
    }

    private fun finish() {
        playing = false
        atEnd = true
        pausedUs = durationUs
        quiet { track?.pause() }
        audioStarted = false
        emit(mapOf("type" to "ended"))
        emitState()
    }

    private fun fail(e: Exception) {
        playing = false
        quiet { track?.pause() }
        emit(mapOf("type" to "error", "message" to describe(e)))
        emitState()
    }

    // =====================================================================================
    // Clock
    // =====================================================================================

    /** Media time "now". Audio-master when the AudioTrack reports timestamps, wall clock otherwise. */
    private fun clockUs(): Long {
        if (!opened) return 0L
        if (!playing) return pausedUs
        val now = System.nanoTime()
        val t = track
        if (t != null && audioStarted && audioBaseSet) {
            try {
                if (t.getTimestamp(ts)) {
                    val frames = ts.framePosition - headBase
                    if (frames >= 0) {
                        val atTs = audioBaseUs + frames * 1_000_000L / sampleRate
                        val us = atTs + ((now - ts.nanoTime) / 1000.0 * speed).toLong()
                        anchorUs = us
                        anchorNs = now
                        return us
                    }
                }
            } catch (ignored: Exception) {
            }
        }
        return anchorUs + ((now - anchorNs) / 1000.0 * speed).toLong()
    }

    private fun positionUs(): Long {
        val p = if (playing) clockUs() else pausedUs
        return if (durationUs > 0) p.coerceIn(0L, durationUs) else max(p, 0L)
    }

    // =====================================================================================
    // Main loop
    // =====================================================================================

    private fun tick(): Boolean {
        if (!opened) return false
        ensureVideoCodec()

        // A seek whose frame never shows (no surface, slow software decode) must still complete.
        if (seekDone != null && System.nanoTime() - seekStartNs > 1_500_000_000L) finishSeek()

        if (playing || needFirstFrame) {
            try {
                vInEos = feed(vEx, vCodec, vInEos)
                drainVideo()
            } catch (e: Exception) {
                onVideoError(e)
            }
        }
        if (playing) {
            try {
                aInEos = feed(aEx, aCodec, aInEos)
                drainAudio()
            } catch (e: Exception) {
                onAudioError(e)
            }
            checkEnded()
        }
        val now = System.nanoTime()
        if (playing && now - lastEmitNs > 100_000_000L) emitState()
        return playing || (needFirstFrame && vCodec != null)
    }

    private fun feed(ex: MediaExtractor?, c: MediaCodec?, eos: Boolean): Boolean {
        if (ex == null || c == null || eos) return eos
        var n = 0
        while (n++ < 6) {
            val i = c.dequeueInputBuffer(0)
            if (i < 0) return false
            val buf = c.getInputBuffer(i) ?: return false
            val size = ex.readSampleData(buf, 0)
            if (size < 0) {
                c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                return true
            }
            c.queueInputBuffer(i, 0, size, ex.sampleTime, 0)
            ex.advance()
        }
        return false
    }

    // ---- video ----

    private fun drainVideo() {
        val c = vCodec ?: return
        if (vOutDone) return
        if (!playing && !needFirstFrame) return
        var n = 0
        while (n++ < 4) {
            if (pendingV < 0) {
                val i = c.dequeueOutputBuffer(vInfo, 0)
                if (i == MediaCodec.INFO_TRY_AGAIN_LATER) return
                if (i < 0) continue // format / buffers changed
                pendingV = i
                pendingVPts = vInfo.presentationTimeUs
                pendingVFlags = vInfo.flags
            }
            if (pendingVFlags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                c.releaseOutputBuffer(pendingV, false)
                pendingV = -1
                vOutDone = true
                if (needFirstFrame) {
                    needFirstFrame = false
                    finishSeek()
                }
                return
            }
            // accurate seek: decode from the keyframe but never show frames before the target
            if (pendingVPts < skipBeforeUs) {
                c.releaseOutputBuffer(pendingV, false)
                pendingV = -1
                continue
            }
            val nowNs = System.nanoTime()
            if (needFirstFrame) {
                c.releaseOutputBuffer(pendingV, true)
                pendingV = -1
                lastRenderNs = nowNs
                pausedUs = pendingVPts
                anchorUs = pendingVPts
                anchorNs = nowNs
                needFirstFrame = false
                finishSeek()
                if (!playing) return
                continue
            }
            val delayUs = ((pendingVPts - clockUs()).toDouble() / speed).toLong()
            if (delayUs > 20_000L) return // not time yet, keep the frame for the next tick
            val dropIt = delayUs < -40_000L && nowNs - lastRenderNs < 250_000_000L
            if (dropIt) {
                c.releaseOutputBuffer(pendingV, false)
            } else {
                c.releaseOutputBuffer(pendingV, nowNs + max(delayUs, 0L) * 1000L)
                lastRenderNs = nowNs
            }
            pendingV = -1
        }
    }

    // ---- audio ----

    private fun setupTrack(fmt: MediaFormat) {
        val sr = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val enc = if (fmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) fmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
        else AudioFormat.ENCODING_PCM_16BIT
        val mask = when (ch) {
            1 -> AudioFormat.CHANNEL_OUT_MONO
            2 -> AudioFormat.CHANNEL_OUT_STEREO
            4 -> AudioFormat.CHANNEL_OUT_QUAD
            6 -> AudioFormat.CHANNEL_OUT_5POINT1
            8 -> AudioFormat.CHANNEL_OUT_7POINT1_SURROUND
            else -> AudioFormat.CHANNEL_OUT_STEREO
        }
        val bps = when (enc) {
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            AudioFormat.ENCODING_PCM_8BIT -> 1
            else -> 2
        }
        val minBuf = AudioTrack.getMinBufferSize(sr, mask, enc)
        val size = max(minBuf * 4, sr * ch * bps / 2) // at least half a second
        track?.let { t -> quiet { t.release() } }
        track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder().setEncoding(enc).setSampleRate(sr).setChannelMask(mask).build()
            )
            .setBufferSizeInBytes(size)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        sampleRate = sr
        bytesPerFrame = ch * bps
        audioBaseSet = false
        audioStarted = false
        writtenSinceFlush = 0
    }

    private fun startTrack() {
        val t = track ?: return
        t.play()
        audioStarted = true
        applyParams()
    }

    private fun applyParams() {
        val t = track ?: return
        if (!audioStarted) return // applied in startTrack(); setting params on a stopped track can restart it
        try {
            t.setPlaybackParams(
                PlaybackParams()
                    .setSpeed(speed)
                    .setPitch(pitch)
                    .setAudioFallbackMode(PlaybackParams.AUDIO_FALLBACK_MODE_DEFAULT)
            )
        } catch (e: Exception) {
            emit(mapOf("type" to "error", "message" to "Speed/pitch not supported here: ${e.message}"))
        }
    }

    private fun drainAudio() {
        val c = aCodec ?: return
        // (re)start the track once enough PCM is queued, also after pause/resume
        if (!audioStarted && track != null && playing &&
            (writtenSinceFlush >= sampleRate.toLong() * bytesPerFrame / 5 || aOutDone)
        ) startTrack()
        if (aOutDone) return
        var n = 0
        while (n++ < 8) {
            if (pendingA < 0) {
                val i = c.dequeueOutputBuffer(aInfo, 0)
                if (i == MediaCodec.INFO_TRY_AGAIN_LATER) return
                if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    setupTrack(c.outputFormat)
                    continue
                }
                if (i < 0) continue
                pendingA = i
                pendingAOff = aInfo.offset
                pendingARemain = aInfo.size
                pendingAPts = aInfo.presentationTimeUs
                pendingAFlags = aInfo.flags
            }
            val t = track
            if (pendingARemain > 0 && t != null) {
                val buf = c.getOutputBuffer(pendingA) ?: return
                buf.position(pendingAOff)
                buf.limit(pendingAOff + pendingARemain)
                if (!audioBaseSet) {
                    audioBaseUs = pendingAPts
                    headBase = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                    audioBaseSet = true
                }
                val w = t.write(buf, pendingARemain, AudioTrack.WRITE_NON_BLOCKING)
                if (w < 0) throw IllegalStateException("AudioTrack write error $w")
                pendingAOff += w
                pendingARemain -= w
                writtenSinceFlush += w
                if (pendingARemain > 0) return // track buffer full, retry next tick
            }
            c.releaseOutputBuffer(pendingA, false)
            pendingA = -1
            if (pendingAFlags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                aOutDone = true
                return
            }
        }
    }

    private fun checkEnded() {
        val audioDone = aCodec == null || aOutDone
        val videoDone = when {
            vFormat == null -> true
            vCodec != null -> vOutDone && pendingV < 0
            else -> durationUs > 0 && clockUs() >= durationUs
        }
        if (audioDone && videoDone && pendingA < 0) {
            // let the tail of the audio buffer play out
            if (durationUs <= 0 || clockUs() >= durationUs - 150_000L) finish()
        }
    }

    // =====================================================================================
    // Audio focus + events
    // =====================================================================================

    private fun requestFocus() {
        if (Build.VERSION.SDK_INT < 26) return
        quiet {
            if (focus == null) {
                focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build()
                    )
                    .setOnAudioFocusChangeListener { change ->
                        if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                            h.post { doPause() }
                        }
                    }
                    .build()
            }
            audioManager.requestAudioFocus(focus!!)
        }
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT < 26) return
        quiet { focus?.let { audioManager.abandonAudioFocusRequest(it) } }
    }

    private fun emit(m: Map<String, Any?>) {
        main.post { sink(m) }
    }

    private fun emitState() {
        lastEmitNs = System.nanoTime()
        emit(
            mapOf(
                "type" to "state",
                "playing" to playing,
                "positionMs" to positionUs() / 1000,
                "durationMs" to durationUs / 1000,
            )
        )
    }
}
