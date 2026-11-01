import 'package:flutter/material.dart';

import '../engine/native_video.dart';

/// Shows the decoder's Flutter texture. The codec's rotation hint is applied here.
class NativeVideoView extends StatelessWidget {
  final NativeVideoValue value;
  const NativeVideoView({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final id = value.textureId;
    if (id == null || !value.hasVideo) return const ColoredBox(color: Colors.black);
    return ColoredBox(
      color: Colors.black,
      child: RotatedBox(quarterTurns: value.quarterTurns, child: Texture(textureId: id)),
    );
  }
}
