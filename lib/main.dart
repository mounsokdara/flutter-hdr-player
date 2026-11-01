import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'background_playback.dart';
import 'engine/player_engine.dart';
import 'hdr_classifier.dart';
import 'ui/controls.dart';
import 'ui/video_surface.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // One engine: libmdk. Hardware decode first (MediaCodec), automatic FFmpeg software
  // fallback after it. No "tunnel" mode, so HDR is tone-mapped by the OpenGL renderer.
  fvp.registerWith(options: {
    'platforms': ['android'],
    'video.decoders': ['AMediaCodec', 'FFmpeg', 'dav1d'],
  });
  BackgroundPlayback.init();
  runApp(const HdrPlayerApp());
}

class HdrPlayerApp extends StatelessWidget {
  const HdrPlayerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HDR Player',
        theme: ThemeData(colorSchemeSeed: Colors.deepOrange, brightness: Brightness.dark, useMaterial3: true),
        home: const PlayerPage(),
      );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  final engine = PlayerEngine();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    engine.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !engine.backgroundEnabled) engine.pause();
  }

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = res?.files.single.path;
    if (path != null) await engine.open(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HDR Player')),
      floatingActionButton: ListenableBuilder(
        listenable: engine,
        builder: (_, __) => FloatingActionButton.extended(
          onPressed: engine.loading ? null : _pick,
          icon: const Icon(Icons.video_file),
          label: const Text('Open video'),
        ),
      ),
      body: ListenableBuilder(
        listenable: engine,
        builder: (context, _) {
          final v = engine.verdict;
          final i = engine.info;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (engine.loading) const LinearProgressIndicator(),
              if (engine.error != null) Text(engine.error!, style: const TextStyle(color: Colors.redAccent)),
              if (engine.ready) ...[
                VideoSurface(engine: engine),
                SeekRow(engine: engine),
                OptionChips(engine: engine),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('libmdk · hardware decode → FFmpeg fallback · double-tap ±10 s',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),
              ],
              if (v != null && i != null) ...[
                const SizedBox(height: 12),
                Chip(
                  avatar: Icon(v.isHdr ? Icons.hdr_on : Icons.hdr_off),
                  label: Text(v.label),
                  backgroundColor: v.isHdr ? Colors.deepOrange.withOpacity(.35) : null,
                ),
                Text(v.reason),
                const Divider(height: 24),
                _row('Codec', i.mime),
                _row('Resolution', '${i.width}×${i.height}'),
                _row('Frame rate', i.frameRate > 0 ? '${i.frameRate.toStringAsFixed(1)} fps' : 'n/a'),
                _row('Primaries', standardName(i.colorStandard)),
                _row('Transfer', transferName(i.colorTransfer)),
                _row('Range', rangeName(i.colorRange)),
                _row('Bit depth', '${i.bitDepth}-bit'),
                _row('Mastering peak', i.maxLuminance > 0 ? '${i.maxLuminance.toStringAsFixed(0)} nits' : 'n/a'),
                _row('MaxCLL / MaxFALL', '${i.maxCll.toStringAsFixed(0)} / ${i.maxFall.toStringAsFixed(0)} nits'),
              ] else if (!engine.loading && !engine.ready)
                const Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: Center(child: Text('Pick a video to detect HLG / PQ / BT.2020 HDR')),
                ),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.white60))),
          Expanded(child: Text(v)),
        ]),
      );
}
