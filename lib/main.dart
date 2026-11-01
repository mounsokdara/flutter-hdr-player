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
  mpvHdr('mpv HDR'),
  mpvCopy('mpv hw-copy'),
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
  String? _mpvProbe;
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
      _mpvProbe = null;
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
            await _startMpv(path, hdrPipeline: true, exoError: e is PlatformException ? (e.message ?? '$e') : '$e');
          }
        case PlayMode.exo:
          await _startExo(path);
        case PlayMode.mpvHdr:
          await _startMpv(path, hdrPipeline: true);
        case PlayMode.mpvCopy:
          await _startMpv(path, hwdec: 'mediacodec-copy');
        case PlayMode.mpvSoft:
          await _startMpv(path, hwdec: 'no');
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
        _startMpv(path, hdrPipeline: true, exoError: c.value.errorDescription ?? 'unknown');
      }
    });
    await c.setLooping(true);
    await c.play();
    setState(() {
      _controller = c;
      _engine = 'ExoPlayer';
    });
  }

  Future<void> _prop(Player p, String name, String value) async {
    try {
      final platform = p.platform;
      if (platform is NativePlayer) await platform.setProperty(name, value);
    } catch (_) {}
  }

  Future<String> _getProp(Player p, String name) async {
    try {
      final platform = p.platform;
      if (platform is NativePlayer) return (await platform.getProperty(name)).trim().toLowerCase();
    } catch (_) {}
    return '';
  }

  /// libmpv path. Render recipe taken from video-player.Dev:
  ///  - surface attached only after mpv knows the video params (avoids black frames)
  ///  - hw-copy decode first, probe the stream with mpv's own video-params
  ///  - for HDR / deep-color sources: software decode + vf=format=yuv420p,
  ///    tone-mapping auto, hdr-compute-peak auto, target-peak 400, then re-seek.
  Future<void> _startMpv(String path, {String hwdec = 'auto-copy', bool hdrPipeline = false, String? exoError}) async {
    await _disposePlayers();
    final p = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    final vc = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: hwdec,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );
    await _prop(p, 'hwdec', hwdec);
    await _prop(p, 'hwdec-codecs', 'h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video');
    await _prop(p, 'video-sync', 'audio');
    await _prop(p, 'vd-lavc-dr', 'no');
    for (final kv in const {
      'vf': '',
      'tone-mapping': 'auto',
      'hdr-compute-peak': 'auto',
      'target-peak': 'auto',
      'target-trc': 'auto',
      'target-prim': 'auto',
      'gamut-mapping-mode': 'auto',
      'gamma': '0',
      'video-output-levels': 'auto',
      'dither-depth': 'no',
    }.entries) {
      await _prop(p, kv.key, kv.value);
    }

    await p.open(Media(Uri.file(path).toString()), play: false);

    // Wait for decoded video params (same idea as the Dev player's probe loop).
    var pix = '', gamma = '';
    for (var i = 0; i < 50; i++) {
      pix = await _getProp(p, 'video-params/pixelformat');
      gamma = await _getProp(p, 'video-params/gamma');
      if (pix.isNotEmpty && gamma.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    final prim = await _getProp(p, 'video-params/primaries');
    final matrix = await _getProp(p, 'video-params/colormatrix');
    final sigPeak = await _getProp(p, 'video-params/sig-peak');

    final peak = double.tryParse(sigPeak) ?? 0;
    final deep = RegExp(r'p0(10|12|16)|p(10|12|14|16)(le|be)?$').hasMatch(pix);
    final hdr = gamma.contains('hlg') || gamma.contains('pq') || gamma.contains('2084') || gamma.contains('2100') ||
        (prim.contains('2020') && (peak > 1.1 || deep)) || matrix.contains('2020');
    var look = 'SDR source';
    if (hdrPipeline && (hdr || deep)) {
      await _prop(p, 'hwdec', 'no'); // software decode, as the Dev player does for HDR
      await _prop(p, 'vf', 'format=yuv420p');
      await _prop(p, 'target-peak', '400');
      look = 'HDR look (sw decode, format=yuv420p, target-peak 400)';
      try {
        await p.seek(p.state.position);
      } catch (_) {}
    }
    await p.play();

    setState(() {
      _mkPlayer = p;
      _mkController = vc;
      _mpvProbe = 'pix=$pix gamma=$gamma prim=$prim matrix=$matrix sig-peak=$sigPeak\n$look';
      _engine = 'libmpv · ${hdrPipeline ? "HDR pipeline" : hwdec}';
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
          if (_mpvProbe != null) Text('mpv: $_mpvProbe', style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
