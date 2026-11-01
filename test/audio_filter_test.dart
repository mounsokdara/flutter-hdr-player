import 'package:flutter_test/flutter_test.dart';
import 'package:hdr_player/audio_filter.dart';

void main() {
  double product(List<double> l) => l.fold(1.0, (a, b) => a * b);

  test('no filter when pitch is unchanged', () {
    expect(buildPitchFilter(1.0), '');
    expect(buildPitchFilter(1.001), '');
  });

  test('octave up: asetrate doubles, atempo halves', () {
    final f = buildPitchFilter(2.0);
    expect(f, contains('asetrate=96000'));
    expect(f, contains('atempo=0.50000'));
  });

  test('atempo chain stays inside 0.5..2 and multiplies to the target', () {
    for (final target in [0.25, 0.4, 0.5, 1.0, 1.7, 2.0, 3.5, 4.0]) {
      final chain = atempoChain(target);
      expect(chain.every((f) => f >= 0.5 && f <= 2.0), true, reason: '$target');
      expect(product(chain), closeTo(target, 1e-9));
    }
  });

  test('pitch 4x (tape at 4x speed) needs a two-step atempo', () {
    final f = buildPitchFilter(4.0);
    expect(RegExp('atempo=').allMatches(f).length, 2);
  });

  test('semitones to factor', () {
    expect(semitonesToFactor(12), closeTo(2.0, 1e-9));
    expect(semitonesToFactor(-12), closeTo(0.5, 1e-9));
    expect(semitonesToFactor(0), closeTo(1.0, 1e-9));
  });
}
