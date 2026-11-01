import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../background_playback.dart';
import '../hdr_classifier.dart';
import '../pitch.dart';
import 'native_video.dart';

const seekStepSeconds = 10;

/// App-level state on top of our native engine: seeking policy, speed/pitch,
/// background playback and HDR metadata.
class PlayerEngine extends ChangeNotifier {
  static const _probeChannel = MethodChannel('hdr_probe');

  PlayerEngine() {
    video.onEnded = _onEnded;
    video.onError = (m) {
      error = m;
      notifyListeners();
    };
    video.addListener(_onValue);
    BackgroundPlayback.onAction = _onNotificationAction;
    _resync = Timer.periodic(const Duration(seconds: 5), (_) => _bgPush());
  }

  final NativeVideoController video = NativeVideoController();

  String? path;
  String? error;
  bool loading = false;
  VideoColorInfo? info;
  HdrVerdict? verdict;

  double speed = 1.0;
  bool pitchLinked = false; // true: pitch == speed (tape style)
  double semitones = 0;
  bool backgroundEnabled = true;

  bool get ready => video.value.initialized;
  bool get playing => video.value.playing;
  Duration get duration => video.value.duration;
  String get title => path == null ? 'HDR Player' : path!.split('/').last;
  double get pitchFactor => pitchLinked ? speed : semitonesToFactor(semitones);

  /// What the UI shows: the pending seek target if any, else the real position.
  Duration get position => _target ?? video.value.position;

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

  /// Double-tap / notification buttons. Taps in quick succession just move the target;
  /// one accurate seek runs after the user stops tapping.
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
    if (!ready || _seeking) return;
    _seeking = true;
    try {
      while (_target != null) {
        final t = _target!;
        final fast = _scrubbing;
        try {
          await video.seek(t, accurate: !fast);
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
  Future<void> play() => video.play();
  Future<void> pause() => video.pause();
  Future<void> togglePlay() => playing ? pause() : play();

  void _onEnded() {
    // loop
    video.play();
  }

  // ---- speed / pitch (AudioTrack PlaybackParams in the native engine) ----
  Timer? _pitchTimer;

  Future<void> setSpeed(double v) async {
    speed = v;
    notifyListeners();
    await video.setSpeed(v);
    if (pitchLinked) _schedulePitch();
    _bgPush();
  }

  void setPitchLinked(bool v) {
    pitchLinked = v;
    notifyListeners();
    _schedulePitch();
  }

  void setSemitones(double v) {
    semitones = v;
    notifyListeners();
    _schedulePitch();
  }

  void resetPitch() {
    semitones = 0;
    pitchLinked = false;
    notifyListeners();
    _schedulePitch();
  }

  void _schedulePitch() {
    _pitchTimer?.cancel();
    _pitchTimer = Timer(const Duration(milliseconds: 120), () => video.setPitch(pitchFactor));
  }

  // ---- open ----
  Future<void> open(String file) async {
    path = file;
    error = null;
    loading = true;
    info = null;
    verdict = null;
    _target = null;
    notifyListeners();

    try {
      final map = await _probeChannel.invokeMapMethod<dynamic, dynamic>('probe', {'path': file});
      info = VideoColorInfo.fromMap(map ?? {});
      verdict = classifyHdr(info!);
    } catch (_) {
      // metadata is informational; playback does not depend on it
    }
    notifyListeners();

    try {
      await video.setHdrMode(verdict?.isHdr ?? false);
      await video.open(file);
      await video.setSpeed(speed);
      await video.setPitch(pitchFactor);
      await video.play();
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
    if (!backgroundEnabled || !_bgStarted || !ready) return;
    BackgroundPlayback.update(title, playing, position, duration, speed);
  }

  void _bgStart() {
    if (!backgroundEnabled || !ready) return;
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
    _pitchTimer?.cancel();
    _resync?.cancel();
    BackgroundPlayback.onAction = null;
    BackgroundPlayback.stop();
    video.removeListener(_onValue);
    video.dispose();
    super.dispose();
  }
}
