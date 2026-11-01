package com.example.hdr_player

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** A plain SurfaceView: the decoder renders straight into it, so the system does HDR output. */
class VideoPlatformView(context: Context) : PlatformView {
    private val sv = SurfaceView(context)

    init {
        sv.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                PlayerHolder.player?.setSurface(holder.surface)
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                PlayerHolder.player?.detachSurfaceBlocking()
            }
        })
    }

    override fun getView(): View = sv

    override fun dispose() {
        PlayerHolder.player?.detachSurfaceBlocking()
    }
}

class VideoViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = VideoPlatformView(context)
}
