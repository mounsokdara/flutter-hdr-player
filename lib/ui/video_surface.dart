import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../engine/player_engine.dart';

/// Video + gestures: single tap = play/pause, double-tap left/right = -/+ 10 s
/// (repeated taps stack: 10, 20, 30 ...).
class VideoSurface extends StatefulWidget {
  final PlayerEngine engine;
  const VideoSurface({super.key, required this.engine});

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  int _stack = 0; // negative = backwards
  Timer? _hide;

  void _tap(bool forward) {
    if ((_stack > 0) != forward) _stack = 0;
    _stack += forward ? seekStepSeconds : -seekStepSeconds;
    widget.engine.nudge(forward ? seekStepSeconds : -seekStepSeconds);
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _stack = 0);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.engine.controller!;
    return AspectRatio(
      aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
      child: LayoutBuilder(builder: (context, box) {
        var downX = 0.0;
        return Stack(fit: StackFit.expand, children: [
          VideoPlayer(c),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTapDown: (d) => downX = d.localPosition.dx,
            onDoubleTap: () => _tap(downX > box.maxWidth / 2),
            onTap: widget.engine.togglePlay,
          ),
          IgnorePointer(
            child: Row(children: [
              Expanded(child: _badge(_stack < 0, Icons.fast_rewind)),
              Expanded(child: _badge(_stack > 0, Icons.fast_forward)),
            ]),
          ),
        ]);
      }),
    );
  }

  Widget _badge(bool on, IconData icon) => AnimatedOpacity(
        opacity: on ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(24)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon),
              const SizedBox(width: 6),
              Text('${_stack.abs()} s'),
            ]),
          ),
        ),
      );
}
