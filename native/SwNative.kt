package com.example.hdr_player

import android.view.Surface
import java.nio.ByteBuffer

/**
 * JNI bridge to the software video decoder (FFmpeg libavcodec, decode only). Used only for streams
 * the phone's own decoders cannot handle, such as HEVC Main 10 on chips without 10-bit support.
 */
object SwNative {
    val available: Boolean = try {
        System.loadLibrary("swdecode")
        true
    } catch (e: Throwable) {
        false
    }

    const val NONE = Long.MIN_VALUE
    const val EOS = Long.MIN_VALUE + 1
    const val ERR = Long.MIN_VALUE + 2

    @JvmStatic external fun nCreate(csd: ByteArray, threads: Int): Long
    @JvmStatic external fun nSetSurface(h: Long, surface: Surface)
    @JvmStatic external fun nSend(h: Long, buf: ByteBuffer, size: Int, ptsUs: Long): Int
    @JvmStatic external fun nSendEos(h: Long): Int
    @JvmStatic external fun nReceive(h: Long): Long
    @JvmStatic external fun nPresent(h: Long): Int
    @JvmStatic external fun nDrop(h: Long)
    @JvmStatic external fun nFlush(h: Long)
    @JvmStatic external fun nSetSkip(h: Long, mode: Int)
    @JvmStatic external fun nRelease(h: Long)
}
