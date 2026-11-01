# HDR Player (Flutter)

Single engine: **libmdk via [fvp](https://pub.dev/packages/fvp)**. Hardware decode first (MediaCodec),
automatic FFmpeg software fallback, HDR tone-mapped by the renderer.

Structure
- `lib/engine/player_engine.dart` - controller, seeking, speed/pitch, background play, HDR metadata
- `lib/audio_filter.dart` - pitch shift built from core FFmpeg filters (aresample/asetrate/atempo)
- `lib/ui/` - video surface (double-tap seek), seek bar, speed/pitch/background chips
- `native/` - MediaExtractor HDR probe + foreground media-notification service

Seeking: one seek in flight at a time, latest target wins. Dragging uses fast keyframe seeks for a live
preview and one accurate seek on release; stacked double-taps commit one seek after 280 ms.

Pitch: independent semitone shift (-12..+12) or linked to speed (tape style). Speed 0.5-4x
(libmdk uses FFmpeg atempo, minimum 0.5).

HDR detection: HLG / PQ (ST 2084, BT.2100), Dolby Vision, or BT.2020 with 10-bit+ or peak >= 400 nits.
