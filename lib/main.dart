import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:video_player/video_player.dart';

import 'background_playback.dart';
import 'hdr_classifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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

enum PlayMode {
  auto('Auto'),
  exo('ExoPlayer'),
  mpvHdr('mpv HDR'),
  mpvCopy('mpv hw-copy'),
  mpvSoft('mpv software');

  final String label;
  const PlayMode(this.label);
}

const _speeds = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];
const _seekStep = 10; // seconds, double-tap and notification buttons

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('hdr_probe');

  String? _path;
  PlayMode _mode = PlayMode.auto;
  VideoPlayerController? _controller; // ExoPlayer
  Player? _mkPlayer; // libmpv
  VideoController? _mkController;
  String? _mpvProbe;
  String? _engine;
  VideoColorInfo? _info;
  HdrVerdict? _verdict;
  String? _error;
  bool _loading = false;

  // tempo / background / gestures
  double _speed = 1.0;
  bool _pitchShift = false; // true: pitch follows speed (tape-style); false: pitch preserved
  bool _bg = true;
  bool _bgStarted = false;
  bool _lastBgPlaying = true;
  int _ticks = 0;
  Timer? _timer;
  bool _dragging = false;
  double _dragMs = 0;
  int _flashSecs = 0; // accumulated double-tap seek, negative = backwards
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    BackgroundPlayback.onAction = _onNotificationAction;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _onTick());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _flashTimer?.cancel();
    BackgroundPlayback.onAction = null;
    BackgroundPlayback.stop();
    _controller?.dispose();
    _mkPlayer?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // With background play off, behave like a normal player: pause when hidden.
    if (state == AppLifecycleState.paused && !_bg) _pause();
  }

  // ---------- unified engine access ----------
  bool get _hasPlayer => _controller != null || _mkPlayer != null;
  Duration get _pos => _mkPlayer?.state.position ?? _controller?.value.position ?? Duration.zero;
  Duration get _dur => _mkPlayer?.state.duration ?? _controller?.value.duration ?? Duration.zero;
  bool get _playing => _mkPlayer?.state.playing ?? _controller?.value.isPlaying ?? false;
  String get _title => _path == null ? 'HDR Player' : _path!.split('/').last;

  Future<void> _play() async {
    await _mkPlayer?.play();
    await _controller?.play();
    _bgPush();
  }

  Future<void> _pause() async {
    await _mkPlayer?.pause();
    await _controller?.pause();
    _bgPush();
  }

  Future<void> _seekTo(Duration d) async {
    final max = _dur;
    var t = d < Duration.zero ? Duration.zero : d;
    if (max > Duration.zero && t > max) t = max;
    await _mkPlayer?.seek(t);
    await _controller?.seekTo(t);
    _bgPush(posOverride: t);
  }

  Future<void> _seekBy(int secs) => _seekTo(_pos + Duration(seconds: secs));

  /// Speed on both engines. Pitch shift needs libmpv (audio-pitch-correction=no);
  /// video_player/ExoPlayer only exposes pitch-preserving speed.
  Future<void> _applyTempo() async {
    final p = _mkPlayer;
    if (p != null) {
      await p.setRate(_speed);
      await _prop(p, 'audio-pitch-correction', _pitchShift ? 'no' : 'yes');
    }
    await _controller?.setPlaybackSpeed(_speed);
    _bgPush();
    if (mounted) setState(() {});
  }

  // ---------- background / notification ----------
  void _bgPush({Duration? posOverride}) {
    if (!_bg || !_bgStarted) return;
    _lastBgPlaying = _playing;
    BackgroundPlayback.update(_title, _playing, posOverride ?? _pos, _dur, _speed);
  }

  void _bgStart() {
    if (!_bg) return;
    _bgStarted = true;
    _lastBgPlaying = _playing;
    BackgroundPlayback.start(_title, _playing, _pos, _dur, _speed);
  }

  void _bgStop() {
    _bgStarted = false;
    BackgroundPlayback.stop();
  }

  void _onNotificationAction(String action, int? ms) {
    switch (action) {
      case 'play':
        _play();
      case 'pause':
        _pause();
      case 'rew':
        _seekBy(-_seekStep);
      case 'fwd':
        _seekBy(_seekStep);
      case 'seek':
        if (ms != null) _seekTo(Duration(milliseconds: ms));
      case 'stop':
        _pause();
        _bgStarted = false;
    }
  }

  void _onTick() {
    if (!mounted || !_hasPlayer) return;
    _ticks++;
    // The notification interpolates position itself; only resync on change / every ~5 s.
    if (_bgStarted && (_playing != _lastBgPlaying || _ticks % 10 == 0)) _bgPush();
    if (!_dragging) setState(() {});
  }

  // ---------- file / open ----------
  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = res?.files.single.path;
    if (path == null) return;
    _info = null;
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
    if (_info == null) {
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
      await _applyTempo();
      _bgStart();
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
        _startMpv(path, hdrPipeline: true, exoError: c.value.errorDescription ?? 'unknown').then((_) async {
          await _applyTempo();
          _bgStart();
        });
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

  /// libmpv path. Render recipe from video-player.Dev:
  ///  surface attached after video params, probe with mpv's video-params, then for
  ///  HDR / deep-color: software decode + vf=format=yuv420p + tone-mapping + target-peak 400.
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
    final hdr = gamma.contains('hlg') ||
        gamma.contains('pq') ||
        gamma.contains('2084') ||
        gamma.contains('2100') ||
        (prim.contains('2020') && (peak > 1.1 || deep)) ||
        matrix.contains('2020');
    var look = 'SDR source';
    if (hdrPipeline && (hdr || deep)) {
      await _prop(p, 'hwdec', 'no');
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

  // ---------- UI ----------
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

  void _doubleTapSeek(bool forward) {
    // consecutive taps in the same direction accumulate (+10, +20, ...)
    if ((_flashSecs > 0) != forward) _flashSecs = 0;
    _flashSecs += forward ? _seekStep : -_seekStep;
    _seekBy(forward ? _seekStep : -_seekStep);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _flashSecs = 0);
    });
    setState(() {});
  }

  Widget _videoSurface(double aspect) {
    final c = _controller;
    final mk = _mkController;
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(builder: (context, box) {
        var tapX = 0.0;
        return Stack(fit: StackFit.expand, children: [
          if (mk != null) Video(controller: mk, controls: NoVideoControls),
          if (c != null && c.value.isInitialized) VideoPlayer(c),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTapDown: (d) => tapX = d.localPosition.dx,
            onDoubleTap: () => _doubleTapSeek(tapX > box.maxWidth / 2),
            onTap: () => _playing ? _pause() : _play(),
          ),
          IgnorePointer(
            child: Row(children: [
              Expanded(child: _flash(_flashSecs < 0, Icons.fast_rewind)),
              Expanded(child: _flash(_flashSecs > 0, Icons.fast_forward)),
            ]),
          ),
        ]);
      }),
    );
  }

  Widget _flash(bool on, IconData icon) => AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon),
              const SizedBox(width: 6),
              Text('${_flashSecs.abs()} s'),
            ]),
          ),
        ),
      );

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    String t(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${t(m)}:${t(s)}' : '${t(m)}:${t(s)}';
  }

  Widget _controls() {
    final dur = _dur;
    final durMs = dur.inMilliseconds.toDouble();
    final posMs = _dragging ? _dragMs : _pos.inMilliseconds.toDouble();
    return Column(children: [
      Row(children: [
        IconButton(
          iconSize: 32,
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          onPressed: () => _playing ? _pause() : _play(),
        ),
        Text(_fmt(Duration(milliseconds: posMs.round()))),
        Expanded(
          child: Slider(
            value: durMs <= 0 ? 0 : posMs.clamp(0, durMs),
            max: durMs <= 0 ? 1 : durMs,
            onChangeStart: (_) => _dragging = true,
            onChanged: (v) => setState(() => _dragMs = v),
            onChangeEnd: (v) async {
              await _seekTo(Duration(milliseconds: v.round()));
              _dragging = false;
            },
          ),
        ),
        Text(_fmt(dur)),
      ]),
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        PopupMenuButton<double>(
          initialValue: _speed,
          tooltip: 'Playback speed',
          onSelected: (v) {
            _speed = v;
            _applyTempo();
          },
          itemBuilder: (_) => [
            for (final s in _speeds) PopupMenuItem(value: s, child: Text('${s}×')),
          ],
          child: Chip(avatar: const Icon(Icons.speed, size: 18), label: Text('${_speed}×')),
        ),
        FilterChip(
          avatar: const Icon(Icons.graphic_eq, size: 18),
          label: const Text('Pitch shift'),
          selected: _pitchShift,
          onSelected: (v) {
            if (v && _mkPlayer == null) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('ExoPlayer cannot shift pitch. Choose an mpv mode to use it.')));
            }
            _pitchShift = v;
            _applyTempo();
          },
        ),
        FilterChip(
          avatar: const Icon(Icons.headphones, size: 18),
          label: const Text('Background'),
          selected: _bg,
          onSelected: (v) {
            setState(() => _bg = v);
            if (v) {
              _bgStart();
            } else {
              _bgStop();
            }
          },
        ),
      ]),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          _pitchShift
              ? 'Pitch follows speed (like a tape) · double-tap left/right = ∓$_seekStep s'
              : 'Pitch preserved · double-tap left/right = ∓$_seekStep s',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final v = _verdict;
    final i = _info;
    final aspect = _controller?.value.isInitialized == true
        ? _controller!.value.aspectRatio
        : (i != null && i.width > 0 && i.height > 0 ? i.width / i.height : 16 / 9);
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
          if (_hasPlayer) ...[
            _videoSurface(aspect),
            _controls(),
          ],
          if (_path != null) Padding(padding: const EdgeInsets.only(top: 8), child: _modeBar()),
          if (_engine != null)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Engine: $_engine', style: const TextStyle(color: Colors.white60))),
          if (_mpvProbe != null)
            Text('mpv: $_mpvProbe', style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
            _row('HW decoder',
                i.decoderSupported ? 'OK (${i.decoderName})' : 'Cannot decode this size/fps (max ${i.decoderMaxFps.toStringAsFixed(0)} fps)'),
            _row('Primaries', standardName(i.colorStandard)),
            _row('Transfer', transferName(i.colorTransfer)),
            _row('Range', rangeName(i.colorRange)),
            _row('Bit depth', '${i.bitDepth}-bit'),
            _row('Mastering peak', i.maxLuminance > 0 ? '${i.maxLuminance.toStringAsFixed(0)} nits' : 'n/a'),
            _row('MaxCLL / MaxFALL', '${i.maxCll.toStringAsFixed(0)} / ${i.maxFall.toStringAsFixed(0)} nits'),
          ] else if (!_loading && !_hasPlayer)
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

