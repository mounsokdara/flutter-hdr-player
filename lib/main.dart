import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'hdr_classifier.dart';

void main() => runApp(const HdrPlayerApp());

class HdrPlayerApp extends StatelessWidget {
  const HdrPlayerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'HDR Player',
        theme: ThemeData(colorSchemeSeed: Colors.deepOrange, brightness: Brightness.dark, useMaterial3: true),
        home: const PlayerPage(),
      );
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const _channel = MethodChannel('hdr_probe');

  VideoPlayerController? _controller;
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

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final map = await _channel.invokeMapMethod<dynamic, dynamic>('probe', {'path': path});
      final info = VideoColorInfo.fromMap(map ?? {});
      // Show metadata even if playback later fails.
      setState(() {
        _info = info;
        _verdict = classifyHdr(info);
      });
      final old = _controller;
      final c = VideoPlayerController.file(File(path));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      await old?.dispose();
      setState(() => _controller = c);
    } catch (e) {
      final i = _info;
      final hint = (i != null && !i.decoderSupported)
          ? 'Your device decoder (${i.decoderName.isEmpty ? "none" : i.decoderName}) supports at most '
              '${i.decoderMaxFps.toStringAsFixed(0)} fps at ${i.width}×${i.height}, '
              'but this video is ${i.frameRate.toStringAsFixed(0)} fps. '
              'Re-encode to ≤${i.decoderMaxFps > 0 ? i.decoderMaxFps.toStringAsFixed(0) : "60"} fps '
              '(e.g. ffmpeg -i in.mp4 -vf fps=60 -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 '
              '-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc out.mp4).'
          : '';
      setState(() {
        _controller = null;
        _error = 'Playback failed: ${e is PlatformException ? e.message : e}\n$hint';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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
