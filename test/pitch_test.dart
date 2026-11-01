import 'package:flutter_test/flutter_test.dart';
import 'package:hdr_player/pitch.dart';

void main() {
  test('semitones to pitch factor', () {
    expect(semitonesToFactor(0), closeTo(1.0, 1e-9));
    expect(semitonesToFactor(12), closeTo(2.0, 1e-9));
    expect(semitonesToFactor(-12), closeTo(0.5, 1e-9));
    expect(semitonesToFactor(7), closeTo(1.4983, 1e-3));
  });
}
