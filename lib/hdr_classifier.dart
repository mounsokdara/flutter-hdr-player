/// Android MediaFormat constants (same values as android.media.MediaFormat).
class AndroidColor {
  static const standardBt709 = 1;
  static const standardBt601Pal = 2;
  static const standardBt601Ntsc = 4;
  static const standardBt2020 = 6;

  static const transferLinear = 1;
  static const transferSdrVideo = 3;
  static const transferSt2084 = 6; // PQ
  static const transferHlg = 7;

  static const rangeFull = 1;
  static const rangeLimited = 2;
}

enum HdrKind { sdr, hlg, pq, wideGamutHdr }

class HdrVerdict {
  final HdrKind kind;
  final String reason;
  const HdrVerdict(this.kind, this.reason);
  bool get isHdr => kind != HdrKind.sdr;

  String get label => switch (kind) {
        HdrKind.sdr => 'SDR',
        HdrKind.hlg => 'HDR · HLG',
        HdrKind.pq => 'HDR · PQ (ST 2084)',
        HdrKind.wideGamutHdr => 'HDR · BT.2020 wide gamut',
      };
}

class VideoColorInfo {
  final String mime;
  final int width;
  final int height;
  final int? colorStandard;
  final int? colorTransfer;
  final int? colorRange;
  final int? profile;
  final int bitDepth;
  final double maxLuminance; // mastering display max, cd/m2 (0 = unknown)
  final double maxCll;
  final double maxFall;

  const VideoColorInfo({
    this.mime = '',
    this.width = 0,
    this.height = 0,
    this.colorStandard,
    this.colorTransfer,
    this.colorRange,
    this.profile,
    this.bitDepth = 8,
    this.maxLuminance = 0,
    this.maxCll = 0,
    this.maxFall = 0,
  });

  factory VideoColorInfo.fromMap(Map<dynamic, dynamic> m) => VideoColorInfo(
        mime: (m['mime'] ?? '') as String,
        width: (m['width'] ?? 0) as int,
        height: (m['height'] ?? 0) as int,
        colorStandard: m['colorStandard'] as int?,
        colorTransfer: m['colorTransfer'] as int?,
        colorRange: m['colorRange'] as int?,
        profile: m['profile'] as int?,
        bitDepth: (m['bitDepth'] ?? 8) as int,
        maxLuminance: ((m['maxLuminance'] ?? 0) as num).toDouble(),
        maxCll: ((m['maxCll'] ?? 0) as num).toDouble(),
        maxFall: ((m['maxFall'] ?? 0) as num).toDouble(),
      );

  double get peakNits => maxLuminance > maxCll ? maxLuminance : maxCll;
}

/// Peak (nits) above which BT.2020 content is treated as HDR.
const double kHighPeakNits = 400;

/// Rules:
///  * Transfer HLG or PQ/ST 2084 (BT.2100 = BT.2020 primaries + one of these) -> HDR
///  * Dolby Vision -> HDR
///  * BT.2020 primaries + (10-bit or higher OR high peak luminance) -> HDR
///  * Everything else -> SDR
HdrVerdict classifyHdr(VideoColorInfo i) {
  if (i.colorTransfer == AndroidColor.transferHlg) {
    return const HdrVerdict(HdrKind.hlg, 'Transfer function is HLG (ARIB STD-B67 / BT.2100 HLG)');
  }
  if (i.colorTransfer == AndroidColor.transferSt2084) {
    return const HdrVerdict(HdrKind.pq, 'Transfer function is PQ (SMPTE ST 2084 / BT.2100 PQ)');
  }
  if (i.mime.toLowerCase().contains('dolby-vision')) {
    return const HdrVerdict(HdrKind.pq, 'Dolby Vision stream');
  }
  if (i.colorStandard == AndroidColor.standardBt2020) {
    if (i.bitDepth >= 10) {
      return HdrVerdict(HdrKind.wideGamutHdr, 'BT.2020 primaries with ${i.bitDepth}-bit depth');
    }
    if (i.peakNits >= kHighPeakNits) {
      return HdrVerdict(HdrKind.wideGamutHdr,
          'BT.2020 primaries with high peak (${i.peakNits.toStringAsFixed(0)} nits)');
    }
  }
  return const HdrVerdict(HdrKind.sdr, 'No HDR transfer, BT.2020 + 10-bit, or high peak found');
}

String standardName(int? v) => switch (v) {
      AndroidColor.standardBt709 => 'BT.709',
      AndroidColor.standardBt601Pal => 'BT.601 PAL',
      AndroidColor.standardBt601Ntsc => 'BT.601 NTSC',
      AndroidColor.standardBt2020 => 'BT.2020',
      _ => 'Unknown',
    };

String transferName(int? v) => switch (v) {
      AndroidColor.transferLinear => 'Linear',
      AndroidColor.transferSdrVideo => 'SDR (BT.709 curve)',
      AndroidColor.transferSt2084 => 'PQ / ST 2084',
      AndroidColor.transferHlg => 'HLG',
      _ => 'Unknown',
    };

String rangeName(int? v) => switch (v) {
      AndroidColor.rangeFull => 'Full',
      AndroidColor.rangeLimited => 'Limited',
      _ => 'Unknown',
    };
