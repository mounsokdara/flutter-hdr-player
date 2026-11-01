import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player/video_player.dart';

import 'background_playback.dart';
import 'hdr_classifier.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Single engine: libmdk via fvp. Hardware decode first (MediaCodec), then FFmpeg
  // software decoders automatically when the hardware decoder can't take the stream.
  // Tone-mapped OpenGL rendering is kept (no "tunnel" mode) so HDR looks right on SDR output.
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

// libmdk's playback rate uses FFmpeg atempo, which needs >= 0.5.
const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];
const _seekStep = 10; // seconds, double-tap and notification buttons

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('hdr_probe');

  String? _path;
  VideoPlayerController? _c;
  VideoColorInfo? _info;
  HdrVerdict? _verdict;
  String? _error;
  bool _loading = false;

  double _speed = 1.0;
  bool _pitchShift = false; // pitch follows speed (tape-style) instead of being preserved
  bool _bg = true;
  bool _bgStarted = false;
  bool _lastBgPlaying = true;
  int _ticks = 0;
  Timer? _timer;
  bool _dragging = false;
  double _dragMs = 0;
  int _flashSecs = 0;
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
    _c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_bg) _pause();
  }

  // ---------- engine access ----------
  bool get _ready => _c?.value.isInitialized ?? false;
  Duration get _pos => _c?.value.position ?? Duration.zero;
  Duration get _dur => _c?.value.duration ?? Duration.zero;
  bool get _playing => _c?.value.isPlaying ?? false;
  String get _title => _path == null ? 'HDR Player' : _path!.split('/').last;

  Future<void> _play() async {
    await _c?.play();
    _bgPush();
  }

  Future<void> _pause() async {
    await _c?.pause();
    _bgPush();
  }

  Future<void> _seekTo(Duration d) async {
    final max = _dur;
    var t = d < Duration.zero ? Duration.zero : d;
    if (max > Duration.zero && t > max) t = max;
    await _c?.seekTo(t);
    _bgPush(posOverride: t);
  }

  Future<void> _seekBy(int secs) => _seekTo(_pos + Duration(seconds: secs));

  /// Speed always keeps pitch (FFmpeg atempo inside libmdk). "Pitch shift" adds an
  /// FFmpeg rubberband filter so pitch follows speed, like PlaybackParams pitch == speed.
  Future<void> _applyTempo() async {
    final c = _c;
    if (c == null) return;
    await c.setPlaybackSpeed(_speed);
    try {
      c.setProperty('audio.avfilter', (_pitchShift && _speed != 1.0) ? 'rubberband=pitch=$_speed:tempo=1' : '');
    } catch (_) {}
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
    if (!mounted || _c == null) return;
    _ticks++;
    if (_bgStarted && (_playing != _lastBgPlaying || _ticks % 10 == 0)) _bgPush();
    if (!_dragging) setState(() {});
  }

  // ---------- open ----------
  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video);
    final path = res?.files.single.path;
    if (path == null) return;
    await _open(path);
  }

  Future<void> _open(String path) async {
    _path = path;
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
      _verdict = null;
    });
    final old = _c;
    setState(() => _c = null);
    await old?.dispose();

    // HDR / color metadata straight from the container (MediaExtractor).
    try {
      final map = await _channel.invokeMapMethod<dynamic, dynamic>('probe', {'path': path});
      final info = VideoColorInfo.fromMap(map ?? {});
      setState(() {
        _info = info;
        _verdict = classifyHdr(info);
      });
    } catch (_) {
      // Probe is informational only; playback does not depend on it.
    }

    try {
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      await c.setLooping(true);
      setState(() => _c = c);
      await _applyTempo();
      await c.play();
      _bgStart();
    } catch (e) {
      setState(() => _error = 'Playback failed: ${e is PlatformException ? e.message : e}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------- UI ----------
  void _doubleTapSeek(bool forward) {
    if ((_flashSecs > 0) != forward) _flashSecs = 0;
    _flashSecs += forward ? _seekStep : -_seekStep;
    _seekBy(forward ? _seekStep : -_seekStep);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _flashSecs = 0);
    });
    setState(() {});
  }

  Widget _videoSurface() {
    final c = _c!;
    return AspectRatio(
      aspectRatio: c.value.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        var tapX = 0.0;
        return Stack(fit: StackFit.expand, children: [
          VideoPlayer(c),
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
            for (final s in _speeds) PopupMenuItem(value: s, child: Text('$s×')),
          ],
          child: Chip(avatar: const Icon(Icons.speed, size: 18), label: Text('$_speed×')),
        ),
        FilterChip(
          avatar: const Icon(Icons.graphic_eq, size: 18),
          label: const Text('Pitch shift'),
          selected: _pitchShift,
          onSelected: (v) {
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
              ? 'Pitch follows speed · double-tap left/right = ∓$_seekStep s'
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
          if (_ready) ...[
            _videoSurface(),
            _controls(),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Engine: libmdk (fvp) · hardware decode → FFmpeg fallback',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
            ),
          ],
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
            _row('Primaries', standardName(i.colorStandard)),
            _row('Transfer', transferName(i.colorTransfer)),
            _row('Range', rangeName(i.colorRange)),
            _row('Bit depth', '${i.bitDepth}-bit'),
            _row('Mastering peak', i.maxLuminance > 0 ? '${i.maxLuminance.toStringAsFixed(0)} nits' : 'n/a'),
            _row('MaxCLL / MaxFALL', '${i.maxCll.toStringAsFixed(0)} / ${i.maxFall.toStringAsFixed(0)} nits'),
          ] else if (!_loading && !_ready)
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
