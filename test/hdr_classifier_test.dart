import 'package:flutter_test/flutter_test.dart';
import 'package:hdr_player/hdr_classifier.dart';

void main() {
  test('HLG transfer is HDR', () {
    final v = classifyHdr(const VideoColorInfo(colorTransfer: AndroidColor.transferHlg));
    expect(v.kind, HdrKind.hlg);
  });
  test('PQ / ST2084 (BT.2100) is HDR', () {
    final v = classifyHdr(const VideoColorInfo(
        colorStandard: AndroidColor.standardBt2020, colorTransfer: AndroidColor.transferSt2084));
    expect(v.kind, HdrKind.pq);
  });
  test('BT.2020 + 10-bit is HDR', () {
    final v = classifyHdr(const VideoColorInfo(colorStandard: AndroidColor.standardBt2020, bitDepth: 10));
    expect(v.kind, HdrKind.wideGamutHdr);
  });
  test('BT.2020 + high peak is HDR', () {
    final v = classifyHdr(const VideoColorInfo(colorStandard: AndroidColor.standardBt2020, maxCll: 1000));
    expect(v.kind, HdrKind.wideGamutHdr);
  });
  test('BT.2020 8-bit low peak is SDR', () {
    final v = classifyHdr(const VideoColorInfo(colorStandard: AndroidColor.standardBt2020));
    expect(v.isHdr, false);
  });
  test('BT.709 10-bit is SDR', () {
    final v = classifyHdr(const VideoColorInfo(colorStandard: AndroidColor.standardBt709, bitDepth: 10));
    expect(v.isHdr, false);
  });
}
