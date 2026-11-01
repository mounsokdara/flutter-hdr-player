# HDR Player (Flutter)

Our own playback engine, no third-party player code. Everything runs on Android's platform APIs:

    MediaExtractor (demux) -> MediaCodec (decode) -> SurfaceView / AudioTrack (output)

- `native/NativePlayer.kt` - the engine: single player thread, audio-master clock, A/V sync, frame
  drop, fast (keyframe) and accurate (decode-and-skip) seeking, hardware-then-software decoder
  fallback, audio focus, speed and pitch through `AudioTrack.setPlaybackParams`.
- `native/VideoPlatformView.kt` - a SurfaceView the decoder renders into directly, so the system
  compositor handles HDR output and tone mapping.
- `native/PlaybackService.kt` - foreground media-notification service.
- `native/MainActivity.kt` - channels + HDR metadata probe.
- `lib/engine/` - Dart handle on the engine and the app-level state (seek policy, pitch, background).
- `lib/ui/` - video surface (double-tap seek), seek bar, speed / pitch / background chips.

Limits of "our own": containers and codecs are whatever the phone's Android supports
(MP4, MKV, WebM, TS, 3GP; H.264, HEVC, VP9, AV1 where the device has a decoder).
There is no FFmpeg, so exotic formats (e.g. some AVI, FLV, old codecs) will not play.

Seeking: one seek in flight at a time, latest target wins. Dragging does fast keyframe seeks for a
live preview and one accurate seek on release; stacked double-taps commit one seek after 280 ms.

HDR detection: HLG / PQ (ST 2084, BT.2100), Dolby Vision, or BT.2020 with 10-bit+ or peak >= 400 nits.
