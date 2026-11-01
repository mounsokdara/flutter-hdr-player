import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class NativeVideoValue {
  final bool initialized;
  final bool playing;
  final Duration position;
  final Duration duration;
  final double aspectRatio;
  final bool hasVideo;
  final bool hasAudio;
  final String decoder;

  const NativeVideoValue({
    this.initialized = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.aspectRatio = 16 / 9,
    this.hasVideo = true,
    this.hasAudio = true,
    this.decoder = '',
  });

  NativeVideoValue copyWith({
    bool? initialized,
    bool? playing,
    Duration? position,
    Duration? duration,
    double? aspectRatio,
    bool? hasVideo,
    bool? hasAudio,
    String? decoder,
  }) =>
      NativeVideoValue(
        initialized: initialized ?? this.initialized,
        playing: playing ?? this.playing,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        hasVideo: hasVideo ?? this.hasVideo,
        hasAudio: hasAudio ?? this.hasAudio,
        decoder: decoder ?? this.decoder,
      );
}

/// Thin Dart handle on our own native engine (MediaExtractor / MediaCodec / AudioTrack).
class NativeVideoController extends ValueNotifier<NativeVideoValue> {
  static const _method = MethodChannel('native_player');
  static const _events = EventChannel('native_player/events');

  NativeVideoController() : super(const NativeVideoValue()) {
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
  }

  StreamSubscription<dynamic>? _sub;

  /// Playback reached the end of the file.
  VoidCallback? onEnded;

  /// Native engine reported a problem (decoder, audio params, ...).
  void Function(String message)? onError;

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    switch (e['type']) {
      case 'state':
        value = value.copyWith(
          playing: e['playing'] as bool? ?? value.playing,
          position: Duration(milliseconds: (e['positionMs'] as num?)?.toInt() ?? 0),
          duration: Duration(milliseconds: (e['durationMs'] as num?)?.toInt() ?? 0),
        );
      case 'decoder':
        value = value.copyWith(decoder: e['name'] as String? ?? '');
      case 'ended':
        onEnded?.call();
      case 'error':
        onError?.call(e['message'] as String? ?? 'Playback error');
    }
  }

  Future<void> open(String path) async {
    value = const NativeVideoValue();
    final r = await _method.invokeMapMethod<String, dynamic>('open', {'path': path});
    final w = (r?['width'] as num?)?.toInt() ?? 0;
    final h = (r?['height'] as num?)?.toInt() ?? 0;
    value = NativeVideoValue(
      initialized: true,
      duration: Duration(milliseconds: (r?['durationMs'] as num?)?.toInt() ?? 0),
      aspectRatio: (w > 0 && h > 0) ? w / h : 16 / 9,
      hasVideo: r?['hasVideo'] as bool? ?? true,
      hasAudio: r?['hasAudio'] as bool? ?? true,
    );
  }

  Future<void> play() => _method.invokeMethod('play');
  Future<void> pause() => _method.invokeMethod('pause');

  /// Resolves once the frame after the seek is on screen. [accurate] false = nearest keyframe.
  Future<void> seek(Duration position, {bool accurate = true}) =>
      _method.invokeMethod('seek', {'positionMs': position.inMilliseconds, 'accurate': accurate});

  Future<void> setSpeed(double v) => _method.invokeMethod('setSpeed', {'value': v});
  Future<void> setPitch(double v) => _method.invokeMethod('setPitch', {'value': v});
  /// Headless decoder test of every decoder/config on this device. Returns a text report.
  Future<String> diagnose(String path) async =>
      (await _method.invokeMethod<String>('diagnose', {'path': path})) ?? 'No report';

  Future<void> setHdrMode(bool on) => _method.invokeMethod('setHdrMode', {'value': on});

  @override
  void dispose() {
    _sub?.cancel();
    _method.invokeMethod('release');
    super.dispose();
  }
}
