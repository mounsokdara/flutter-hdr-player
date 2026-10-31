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

enum PlayMode {
  auto('Auto'),
  exo('ExoPlayer'),
  mpvCopy('mpv copy'),
  mpvZero('mpv zero-copy'),
  mpvSoft('mpv software');

  final String label;
  const PlayMode(this.label);
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _channel = MethodChannel('hdr_probe');

  String? _path;
  PlayMode _mode = PlayMode.auto;
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

  Future<void> _open(String path, {PlayMode? mode}) async {
    _path = path;
    if (mode != null) _mode = mode;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _disposePlayers();
    if (_info == null || mode == null) {
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
    }

    try {
      switch (_mode) {
        case PlayMode.auto:
          try {
            await _startExo(path);
          } catch (e) {
            await _startMpv(path, 'mediacodec-copy', exoError: e is PlatformException ? (e.message ?? '$e') : '$e');
          }
        case PlayMode.exo:
          await _startExo(path);
        case PlayMode.mpvCopy:
          await _startMpv(path, 'mediacodec-copy');
        case PlayMode.mpvZero:
          await _startMpv(path, 'mediacodec');
        case PlayMode.mpvSoft:
          await _startMpv(path, 'no');
      }
    } catch (e) {
      setState(() => _error = 'Playback failed: ${e is PlatformException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startExo(String path) async {
    final c = VideoPlayerController.file(File(path));
    await c.initialize();
    c.addListener(() {
      if (c.value.hasError && mounted && _controller == c && _mode == PlayMode.auto) {
        _startMpv(path, 'mediacodec-copy', exoError: c.value.errorDescription ?? 'unknown');
      }
    });
    await c.setLooping(true);
    await c.play();
    setState(() {
      _controller = c;
      _engine = 'ExoPlayer';
    });
  }

  Future<void> _startMpv(String path, String hwdec, {String? exoError}) async {
    await _disposePlayers();
    final p = Player();
    final vc = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != 'no',
        hwdec: hwdec == 'no' ? null : hwdec,
      ),
    );
    await p.open(Media(path));
    setState(() {
      _mkPlayer = p;
      _mkController = vc;
      _engine = 'libmpv · ${hwdec == "no" ? "software decode" : hwdec}';
      _error = exoError == null ? null : 'ExoPlayer rejected it (${exoError.split("\n").first}); using libmpv.';
    });
  }

  Widget _modeBar() => Wrap(
        spacing: 6,
        children: [
          for (final m in PlayMode.values)
            ChoiceChip(
              label: Text(m.label),
              selected: _mode == m,
              onSelected: (_loading || _path == null) ? null : (_) => _open(_path!, mode: m),
            ),
        ],
      );

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
          if (_path != null) Padding(padding: const EdgeInsets.only(top: 8), child: _modeBar()),
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
