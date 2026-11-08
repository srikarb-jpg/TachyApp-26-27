import 'package:flutter_test/flutter_test.dart';
import 'package:tachycardia/heart_rate.dart';

void main() {
  group('parseHeartRateMeasurement', () {
    test('reads 8-bit BPM when flags bit 0 is 0', () {
      expect(parseHeartRateMeasurement([0x00, 72]), 72);
    });

    test('reads 16-bit little-endian BPM when flags bit 0 is 1', () {
      expect(parseHeartRateMeasurement([0x01, 0x2C, 0x01]), 300);
    });

    test('returns null for packets that are too short', () {
      expect(parseHeartRateMeasurement([]), isNull);
      expect(parseHeartRateMeasurement([0x00]), isNull);
      expect(parseHeartRateMeasurement([0x01, 0x48]), isNull);
    });
  });

  group('TachycardiaDetector', () {
    final t0 = DateTime(2026, 1, 1, 12);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('normal at or below threshold', () {
      final d = TachycardiaDetector();
      expect(d.addReading(75, at(0)), HeartRateState.normal);
      expect(d.addReading(100, at(1)), HeartRateState.normal);
    });

    test('0 BPM means no data', () {
      final d = TachycardiaDetector();
      expect(d.addReading(0, at(0)), HeartRateState.noData);
    });

    test('elevated until sustained, then tachycardia', () {
      final d = TachycardiaDetector(sustainFor: const Duration(seconds: 10));
      expect(d.addReading(120, at(0)), HeartRateState.elevated);
      expect(d.addReading(121, at(9)), HeartRateState.elevated);
      expect(d.addReading(122, at(10)), HeartRateState.tachycardia);
    });

    test('a normal reading restarts the timer', () {
      final d = TachycardiaDetector(sustainFor: const Duration(seconds: 10));
      d.addReading(120, at(0));
      d.addReading(80, at(5));
      expect(d.addReading(120, at(6)), HeartRateState.elevated);
      expect(d.addReading(120, at(15)), HeartRateState.elevated);
      expect(d.addReading(120, at(16)), HeartRateState.tachycardia);
    });

    test('reset clears state', () {
      final d = TachycardiaDetector(sustainFor: Duration.zero);
      d.addReading(150, at(0));
      d.reset();
      expect(d.state, HeartRateState.noData);
      expect(d.aboveSince, isNull);
    });
  });
}
