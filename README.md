# HDR Player (Flutter)

Video player that detects HDR and reports why.

Treated as HDR:
- Transfer **HLG** or **PQ / SMPTE ST 2084** (this covers **BT.2100**, which is BT.2020 primaries + PQ/HLG)
- Dolby Vision streams
- **BT.2020** primaries with **10-bit+** depth **or** a high peak (>= 400 nits, from mastering metadata / MaxCLL)

Color metadata is read natively (`MediaExtractor` -> `MediaFormat`) in `native/MainActivity.kt`,
classified in `lib/hdr_classifier.dart`, and played with `video_player` (ExoPlayer).
HDR output needs an HDR-capable display; the manifest sets `android:colorMode="hdr"`.

CI (`.github/workflows/build.yml`) generates the Android scaffold, runs tests, builds a release APK
and uploads it as the `hdr-player-apk` artifact.
