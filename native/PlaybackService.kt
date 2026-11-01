package com.example.hdr_player

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Foreground media service: keeps the process alive and shows a media notification.
 *  It owns no player; every button is forwarded to Dart through MainActivity.emitMedia. */
class PlaybackService : Service() {
    companion object {
        const val CHANNEL = "playback"
        const val NOTIF_ID = 4711
        const val A_PLAY = "hdr.PLAY"
        const val A_PAUSE = "hdr.PAUSE"
        const val A_REW = "hdr.REW"
        const val A_FWD = "hdr.FWD"
        const val A_STOP = "hdr.STOP"

        @Volatile
        var instance: PlaybackService? = null
    }

    private var session: MediaSession? = null
    private var title = "Playing"
    private var playing = true
    private var posMs = 0L
    private var durMs = 0L
    private var speed = 1f
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW).apply {
                    setSound(null, null)
                    setShowBadge(false)
                }
            )
        }
        session = MediaSession(this, "hdr_player").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() { playing = true; MainActivity.emitMedia("play"); refresh() }
                override fun onPause() { playing = false; MainActivity.emitMedia("pause"); refresh() }
                override fun onSkipToNext() = MainActivity.emitMedia("fwd")
                override fun onSkipToPrevious() = MainActivity.emitMedia("rew")
                override fun onSeekTo(pos: Long) { posMs = pos; MainActivity.emitMedia("seek", pos); refresh() }
                override fun onStop() { MainActivity.emitMedia("stop"); shutdown() }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            A_PLAY -> { playing = true; MainActivity.emitMedia("play") }
            A_PAUSE -> { playing = false; MainActivity.emitMedia("pause") }
            A_REW -> MainActivity.emitMedia("rew")
            A_FWD -> MainActivity.emitMedia("fwd")
            A_STOP -> { MainActivity.emitMedia("stop"); shutdown(); return START_NOT_STICKY }
            else -> intent?.let { applyExtras(it) }
        }
        refresh()
        return START_NOT_STICKY
    }

    private fun applyExtras(i: Intent) {
        i.getStringExtra("title")?.let { title = it }
        if (i.hasExtra("playing")) playing = i.getBooleanExtra("playing", playing)
        if (i.hasExtra("positionMs")) posMs = i.getLongExtra("positionMs", posMs)
        if (i.hasExtra("durationMs")) durMs = i.getLongExtra("durationMs", durMs)
        if (i.hasExtra("speed")) speed = i.getFloatExtra("speed", speed)
    }

    /** Called in-process by MainActivity so we never start a service from the background. */
    fun update(t: String?, p: Boolean, pos: Long, dur: Long, spd: Float) {
        t?.let { title = it }
        playing = p; posMs = pos; durMs = dur; speed = spd
        refresh()
    }

    private fun refresh() {
        session?.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, durMs)
                .build()
        )
        val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SEEK_TO or PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or PlaybackState.ACTION_STOP
        session?.setPlaybackState(
            PlaybackState.Builder().setActions(actions)
                .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED, posMs, if (playing) speed else 0f)
                .build()
        )
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(NOTIF_ID, n)
        updateWake()
    }

    private fun pi(action: String): PendingIntent = PendingIntent.getService(
        this, action.hashCode(), Intent(this, PlaybackService::class.java).setAction(action),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
    )

    private fun buildNotification(): Notification {
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        fun act(icon: Int, label: String, a: String) =
            Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi(a)).build()
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(if (playing) "Playing" else "Paused")
            .setContentIntent(open)
            .setOngoing(playing)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .addAction(act(android.R.drawable.ic_media_rew, "-10 s", A_REW))
            .addAction(
                if (playing) act(android.R.drawable.ic_media_pause, "Pause", A_PAUSE)
                else act(android.R.drawable.ic_media_play, "Play", A_PLAY)
            )
            .addAction(act(android.R.drawable.ic_media_ff, "+10 s", A_FWD))
            .addAction(act(android.R.drawable.ic_menu_close_clear_cancel, "Stop", A_STOP))
        @Suppress("DEPRECATION")
        b.setStyle(Notification.MediaStyle().setMediaSession(session?.sessionToken).setShowActionsInCompactView(0, 1, 2))
        return b.build()
    }

    private fun updateWake() {
        if (playing) {
            if (wake == null) {
                wake = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "hdr_player:playback")
            }
            if (wake?.isHeld == false) wake?.acquire(6 * 60 * 60 * 1000L)
        } else if (wake?.isHeld == true) wake?.release()
    }

    private fun shutdown() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (wake?.isHeld == true) wake?.release()
        session?.release()
        session = null
        instance = null
        super.onDestroy()
    }
}
