import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'hdr_classifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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

class _PlayerPageState extends State<PlayerPage> {
  static const _channel = MethodChannel('hdr_probe');

  VideoPlayerController? _controller;
  Player? _mkPlayer;
  VideoController? _mkController;
  String? _engine; // 'ExoPlayer' or 'libmpv (fallback)'
  VideoColorInfo? _info;
  HdrVerdict? _verdict;
  String? _error;
  bool _loading = false;

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = res?.files.single.path;
    if (path == null) return;
    await _open(path);
  }

  Future<void> _disposePlayers() async {
    final c = _controller;
    final p = _mkPlayer;
    setState(() {
      _controller = null;
      _mkPlayer = null;
      _mkController = null;
      _engine = null;
    });
    await c?.dispose();
    await p?.dispose();
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _disposePlayers();
    try {
      final map = await _channel.invokeMapMethod<dynamic, dynamic>('probe', {'path': path});
      final info = VideoColorInfo.fromMap(map ?? {});
      setState(() {
        _info = info;
        _verdict = classifyHdr(info);
      });
    } catch (e) {
      setState(() => _error = 'Probe failed: $e');
    }

    // 1) ExoPlayer (video_player)
    String? exoError;
    try {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      // initialize() can succeed and the renderer fail right after; listen once.
      c.addListener(() {
        if (c.value.hasError && mounted && _controller == c) {
          _fallback(path, c.value.errorDescription ?? 'unknown');
        }
      });
      await c.setLooping(true);
      await c.play();
      setState(() {
        _controller = c;
        _engine = 'ExoPlayer';
      });
    } catch (e) {
      exoError = e is PlatformException ? (e.message ?? '$e') : '$e';
      await _fallback(path, exoError);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 2) libmpv + MediaCodec (no ExoPlayer level check)
  Future<void> _fallback(String path, String exoError) async {
    await _disposePlayers();
    try {
      final p = Player();
      final vc = VideoController(p);
      await p.open(Media(path));
      setState(() {
        _mkPlayer = p;
        _mkController = vc;
        _engine = 'libmpv (fallback)';
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'ExoPlayer failed: ${exoError.split("\n").first}\nFallback failed: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _mkPlayer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final v = _verdict;
    final i = _info;
    return Scaffold(
      appBar: AppBar(title: const Text('HDR Player')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _pick,
        icon: const Icon(Icons.video_file),
        label: const Text('Open video'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          if (c != null && c.value.isInitialized) ...[
            AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: Stack(alignment: Alignment.bottomCenter, children: [
                VideoPlayer(c),
                VideoProgressIndicator(c, allowScrubbing: true),
              ]),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                iconSize: 36,
                icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
              ),
            ]),
          ],
          if (_mkController != null)
            AspectRatio(
              aspectRatio: (i != null && i.width > 0 && i.height > 0) ? i.width / i.height : 16 / 9,
              child: Video(controller: _mkController!),
            ),
          if (_engine != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Engine: $_engine', style: const TextStyle(color: Colors.white60))),
          if (v != null && i != null) ...[
            const SizedBox(height: 8),
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
            _row('HW decoder', i.decoderSupported ? 'OK (${i.decoderName})' : 'Cannot decode this size/fps (max ${i.decoderMaxFps.toStringAsFixed(0)} fps)'),
            _row('Primaries', standardName(i.colorStandard)),
            _row('Transfer', transferName(i.colorTransfer)),
            _row('Range', rangeName(i.colorRange)),
            _row('Bit depth', '${i.bitDepth}-bit'),
            _row('Mastering peak', i.maxLuminance > 0 ? '${i.maxLuminance.toStringAsFixed(0)} nits' : 'n/a'),
            _row('MaxCLL / MaxFALL', '${i.maxCll.toStringAsFixed(0)} / ${i.maxFall.toStringAsFixed(0)} nits'),
          ] else if (!_loading)
            const Padding(
              padding: EdgeInsets.only(top: 80),
              child: Center(child: Text('Pick a video to detect HLG / PQ / BT.2020 HDR')),
            ),
          const SizedBox(height: 80),
        ],
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
