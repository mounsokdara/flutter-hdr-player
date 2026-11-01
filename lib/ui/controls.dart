import 'package:flutter/material.dart';

import '../engine/player_engine.dart';

const speeds = <double>[0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];

String _fmt(Duration d) {
  final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
  String t(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${t(m)}:${t(s)}' : '${t(m)}:${t(s)}';
}

/// Rebuilds only the seek row when the position changes, not the whole page.
class SeekRow extends StatelessWidget {
  final PlayerEngine engine;
  const SeekRow({super.key, required this.engine});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([engine, engine.video]),
      builder: (context, _) {
        final dur = engine.duration;
        final durMs = dur.inMilliseconds.toDouble();
        final pos = engine.position;
        final posMs = pos.inMilliseconds.toDouble().clamp(0, durMs <= 0 ? 1 : durMs).toDouble();
        return Row(children: [
          IconButton(
            iconSize: 32,
            icon: Icon(engine.playing ? Icons.pause : Icons.play_arrow),
            onPressed: engine.togglePlay,
          ),
          SizedBox(width: 48, child: Text(_fmt(pos))),
          Expanded(
            child: Slider(
              value: durMs <= 0 ? 0 : posMs,
              max: durMs <= 0 ? 1 : durMs,
              onChangeStart: (_) => engine.scrubStart(),
              onChanged: (v) => engine.scrubUpdate(Duration(milliseconds: v.round())),
              onChangeEnd: (v) => engine.scrubEnd(Duration(milliseconds: v.round())),
            ),
          ),
          Text(_fmt(dur)),
        ]);
      },
    );
  }
}

class OptionChips extends StatelessWidget {
  final PlayerEngine engine;
  const OptionChips({super.key, required this.engine});

  String get _pitchLabel {
    if (engine.pitchLinked) return 'Pitch = speed';
    final s = engine.semitones;
    if (s.abs() < 0.05) return 'Pitch';
    return 'Pitch ${s > 0 ? '+' : ''}${s.toStringAsFixed(1)} st';
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      PopupMenuButton<double>(
        initialValue: engine.speed,
        tooltip: 'Playback speed',
        onSelected: engine.setSpeed,
        itemBuilder: (_) => [for (final s in speeds) PopupMenuItem(value: s, child: Text('$s×'))],
        child: Chip(avatar: const Icon(Icons.speed, size: 18), label: Text('${engine.speed}×')),
      ),
      ActionChip(
        avatar: const Icon(Icons.graphic_eq, size: 18),
        label: Text(_pitchLabel),
        onPressed: () => _pitchSheet(context),
      ),
      FilterChip(
        avatar: const Icon(Icons.headphones, size: 18),
        label: const Text('Background'),
        selected: engine.backgroundEnabled,
        onSelected: engine.setBackgroundEnabled,
      ),
    ]);
  }

  void _pitchSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListenableBuilder(
        listenable: engine,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pitch', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Link pitch to speed'),
              subtitle: const Text('Tape style: faster = higher'),
              value: engine.pitchLinked,
              onChanged: engine.setPitchLinked,
            ),
            Text(engine.pitchLinked
                ? 'Pitch follows speed (${engine.speed}×)'
                : 'Independent shift: ${engine.semitones >= 0 ? '+' : ''}${engine.semitones.toStringAsFixed(1)} semitones'),
            Slider(
              min: -12,
              max: 12,
              divisions: 48,
              value: engine.semitones,
              label: engine.semitones.toStringAsFixed(1),
              onChanged: engine.pitchLinked ? null : engine.setSemitones,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: engine.resetPitch, child: const Text('Reset')),
            ),
          ]),
        ),
      ),
    );
  }
}
