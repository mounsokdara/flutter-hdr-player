import 'package:flutter/services.dart';

/// Bridge to the native foreground service (media notification + media session).
class BackgroundPlayback {
  static const _ch = MethodChannel('bg_playback');

  /// Called for notification / lock-screen buttons:
  /// play, pause, rew, fwd, seek (positionMs), stop.
  static void Function(String action, int? positionMs)? onAction;

  static void init() {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'media') {
        final m = Map<dynamic, dynamic>.from(call.arguments as Map);
        onAction?.call(m['action'] as String, (m['positionMs'] as num?)?.toInt());
      }
    });
  }

  static Map<String, dynamic> _args(String title, bool playing, Duration pos, Duration dur, double speed) => {
        'title': title,
        'playing': playing,
        'positionMs': pos.inMilliseconds,
        'durationMs': dur.inMilliseconds,
        'speed': speed,
      };

  static Future<void> start(String title, bool playing, Duration pos, Duration dur, double speed) =>
      _safe('start', _args(title, playing, pos, dur, speed));

  static Future<void> update(String title, bool playing, Duration pos, Duration dur, double speed) =>
      _safe('update', _args(title, playing, pos, dur, speed));

  static Future<void> stop() => _safe('stop', null);

  static Future<void> _safe(String m, Object? a) async {
    try {
      await _ch.invokeMethod(m, a);
    } catch (_) {}
  }
}
