import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart' show FVPControllerExtensions;
import 'package:video_player/video_player.dart';

import '../audio_filter.dart';
import '../background_playback.dart';
import '../hdr_classifier.dart';

const seekStepSeconds = 10;

/// Owns the single libmdk-backed controller and everything around it:
/// seeking, tempo/pitch, background playback and HDR metadata.
class PlayerEngine extends ChangeNotifier {
  static const _probeChannel = MethodChannel('hdr_probe');

  PlayerEngine() {
    BackgroundPlayback.onAction = _onNotificationAction;
    _resync = Timer.periodic(const Duration(seconds: 5), (_) => _bgPush());
  }

  // ---- state ----
  VideoPlayerController? controller;
  String? path;
  String? error;
  bool loading = false;
  VideoColorInfo? info;
  HdrVerdict? verdict;

  double speed = 1.0;
  bool pitchLinked = false; // true: pitch == speed (tape style)
  double semitones = 0;
  bool backgroundEnabled = true;

  bool get ready => controller?.value.isInitialized ?? false;
  bool get playing => controller?.value.isPlaying ?? false;
  Duration get duration => controller?.value.duration ?? Duration.zero;
  String get title => path == null ? 'HDR Player' : path!.split('/').last;
  double get pitchFactor => pitchLinked ? speed : semitonesToFactor(semitones);

  /// What the UI should show: the pending seek target if any, else the real position.
  Duration get position => _target ?? controller?.value.position ?? Duration.zero;

  // ---- seeking: latest target wins, never more than one seek in flight ----
  Duration? _target;
  bool _seeking = false;
  bool _scrubbing = false;
  Timer? _commitTimer;

  Duration _clamp(Duration d) {
    final max = duration;
    if (d < Duration.zero) return Duration.zero;
    if (max > Duration.zero && d > max) return max;
    return d;
  }

  /// Double-tap / notification buttons. Taps in quick succession just move the
  /// target; one accurate seek runs after the user stops tapping.
  void nudge(int seconds) {
    if (!ready) return;
    _target = _clamp(position + Duration(seconds: seconds));
    notifyListeners();
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 280), _drain);
  }

  void seekTo(Duration d) {
    if (!ready) return;
    _target = _clamp(d);
    notifyListeners();
    _commitTimer?.cancel();
    _drain();
  }

  void scrubStart() {
    _scrubbing = true;
    _commitTimer?.cancel();
  }

  /// While dragging: fast (keyframe) seeks for a live preview.
  void scrubUpdate(Duration d) {
    _target = _clamp(d);
    notifyListeners();
    _drain();
  }

  /// On release: one accurate seek to the exact spot.
  void scrubEnd(Duration d) {
    _scrubbing = false;
    _target = _clamp(d);
    notifyListeners();
    _drain();
  }

  Future<void> _drain() async {
    final c = controller;
    if (c == null || _seeking) return;
    _seeking = true;
    try {
      while (_target != null) {
        final t = _target!;
        final fast = _scrubbing;
        try {
          if (fast) {
            await c.fastSeekTo(t);
          } else {
            await c.seekTo(t);
          }
        } catch (_) {}
        if (fast && _scrubbing && _target == t) break; // wait for the next drag update
        if (_target == t && !fast) _target = null;
      }
    } finally {
      _seeking = false;
      notifyListeners();
      _bgPush();
    }
  }

  // ---- transport ----
  Future<void> play() async {
    await controller?.play();
    _bgPush();
  }

  Future<void> pause() async {
    await controller?.pause();
    _bgPush();
  }

  Future<void> togglePlay() => playing ? pause() : play();

  // ---- tempo / pitch ----
  Timer? _audioTimer;

  Future<void> setSpeed(double v) async {
    speed = v;
    notifyListeners();
    try {
      await controller?.setPlaybackSpeed(v);
    } catch (_) {}
    _scheduleAudioFilter(); // pitch may follow speed
    _bgPush();
  }

  void setPitchLinked(bool v) {
    pitchLinked = v;
    notifyListeners();
    _scheduleAudioFilter();
  }

  void setSemitones(double v) {
    semitones = v;
    notifyListeners();
    _scheduleAudioFilter();
  }

  void resetPitch() {
    semitones = 0;
    pitchLinked = false;
    notifyListeners();
    _scheduleAudioFilter();
  }

  void _scheduleAudioFilter() {
    _audioTimer?.cancel();
    _audioTimer = Timer(const Duration(milliseconds: 160), _applyAudioFilter);
  }

  void _applyAudioFilter() {
    try {
      controller?.setProperty('audio.avfilter', buildPitchFilter(pitchFactor));
    } catch (_) {}
  }

  // ---- open ----
  Future<void> open(String file) async {
    path = file;
    error = null;
    loading = true;
    info = null;
    verdict = null;
    _target = null;
    final old = controller;
    controller = null;
    notifyListeners();
    old?.removeListener(_onValue);
    await old?.dispose();

    try {
      final map = await _probeChannel.invokeMapMethod<dynamic, dynamic>('probe', {'path': file});
      info = VideoColorInfo.fromMap(map ?? {});
      verdict = classifyHdr(info!);
    } catch (_) {
      // metadata is informational; playback does not depend on it
    }
    notifyListeners();

    try {
      final c = VideoPlayerController.file(File(file));
      await c.initialize();
      await c.setLooping(true);
      c.addListener(_onValue);
      controller = c;
      await c.setPlaybackSpeed(speed);
      _applyAudioFilter();
      await c.play();
      _bgStart();
    } catch (e) {
      error = 'Playback failed: ${e is PlatformException ? e.message : e}';
    }
    loading = false;
    notifyListeners();
  }

  // ---- background / notification ----
  bool _bgStarted = false;
  bool _lastPlaying = false;
  Timer? _resync;

  void _onValue() {
    final p = playing;
    if (p != _lastPlaying) {
      _lastPlaying = p;
      _bgPush();
    }
  }

  void _bgPush() {
    final c = controller;
    if (!backgroundEnabled || !_bgStarted || c == null) return;
    BackgroundPlayback.update(title, playing, position, duration, speed);
  }

  void _bgStart() {
    final c = controller;
    if (!backgroundEnabled || c == null) return;
    _bgStarted = true;
    _lastPlaying = playing;
    BackgroundPlayback.start(title, playing, position, duration, speed);
  }

  void setBackgroundEnabled(bool v) {
    backgroundEnabled = v;
    if (v) {
      _bgStart();
    } else {
      _bgStarted = false;
      BackgroundPlayback.stop();
    }
    notifyListeners();
  }

  void _onNotificationAction(String action, int? ms) {
    switch (action) {
      case 'play':
        play();
      case 'pause':
        pause();
      case 'rew':
        nudge(-seekStepSeconds);
      case 'fwd':
        nudge(seekStepSeconds);
      case 'seek':
        if (ms != null) seekTo(Duration(milliseconds: ms));
      case 'stop':
        pause();
        _bgStarted = false;
    }
  }

  @override
  void dispose() {
    _commitTimer?.cancel();
    _audioTimer?.cancel();
    _resync?.cancel();
    BackgroundPlayback.onAction = null;
    BackgroundPlayback.stop();
    controller?.removeListener(_onValue);
    controller?.dispose();
    super.dispose();
  }
}
