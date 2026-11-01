# HDR Player (Flutter)

One engine: **libmdk via [fvp](https://pub.dev/packages/fvp)**. It decodes in hardware first (MediaCodec)
and falls back to FFmpeg software decoders automatically, so odd formats, levels and frame rates play
without choosing a mode. ExoPlayer and libmpv were removed.

HDR detection (`lib/hdr_classifier.dart`, metadata read natively in `native/MainActivity.kt`):
- Transfer **HLG** or **PQ / ST 2084** (BT.2100 = BT.2020 primaries + one of these)
- Dolby Vision
- **BT.2020** primaries with **10-bit+** depth, or a high peak (>= 400 nits)

Features: background play with media notification (`native/PlaybackService.kt`), double-tap ±10 s,
speed 0.5-4x (libmdk uses FFmpeg atempo, minimum 0.5), optional pitch shift (FFmpeg rubberband filter).

CI builds per-ABI release APKs and uploads them as the `hdr-player-apk` artifact.
