import 'dart:math';

/// 12 semitones = one octave = a factor of 2.
double semitonesToFactor(double semitones) => pow(2, semitones / 12).toDouble();
