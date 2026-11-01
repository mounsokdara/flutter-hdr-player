import 'dart:math';

/// atempo only accepts 0.5..2.0 per instance, so split bigger factors into a chain.
List<double> atempoChain(double factor) {
  final out = <double>[];
  var f = factor;
  while (f < 0.5) {
    out.add(0.5);
    f /= 0.5;
  }
  while (f > 2.0) {
    out.add(2.0);
    f /= 2.0;
  }
  out.add(f);
  return out;
}

/// Pitch factor from semitones (12 semitones = one octave = x2).
double semitonesToFactor(double semitones) => pow(2, semitones / 12).toDouble();

/// Pure pitch shift (tempo unchanged) using only core FFmpeg filters:
///   aresample -> fixed 48 kHz so the maths never depends on the source rate
///   asetrate  -> reinterpret samples at rate*pitch  (pitch x p, tempo x p)
///   aresample -> back to 48 kHz
///   atempo    -> 1/p to cancel the tempo change     (pitch x p, tempo x 1)
/// Returns '' when no shift is needed.
String buildPitchFilter(double pitch) {
  if ((pitch - 1.0).abs() < 0.002) return '';
  const base = 48000;
  final tempo = atempoChain(1.0 / pitch).map((f) => 'atempo=${f.toStringAsFixed(5)}').join(',');
  return 'aresample=$base,asetrate=${(base * pitch).round()},aresample=$base,$tempo';
}
