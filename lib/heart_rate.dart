// heart_rate.dart
//
// Pure logic with no Bluetooth or UI, so it can be unit tested:
//   1. parseHeartRateMeasurement: decodes the standard BLE Heart Rate
//      Measurement characteristic (0x2A37) into a BPM number.
//   2. TachycardiaDetector: decides normal / elevated / tachycardia.

/// Decodes a Heart Rate Measurement (0x2A37) packet.
///
/// Byte 0 is a flags byte. If bit 0 is 0, the BPM is one byte (byte 1).
/// If bit 0 is 1, the BPM is two bytes, little-endian (bytes 1-2).
/// Returns null if the packet is too short to contain a BPM.
int? parseHeartRateMeasurement(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final flags = bytes[0];
  final isUint16 = (flags & 0x01) != 0;

  if (isUint16) {
    if (bytes.length < 3) return null;
    return bytes[1] | (bytes[2] << 8);
  } else {
    if (bytes.length < 2) return null;
    return bytes[1];
  }
}

enum HeartRateState {
  /// No reading yet, or the sensor reported 0 (e.g. no finger on it).
  noData,

  /// At or below the threshold.
  normal,

  /// Above the threshold, but not for long enough to call it tachycardia.
  elevated,

  /// Above the threshold for at least [TachycardiaDetector.sustainFor].
  tachycardia,
}

/// Flags tachycardia when BPM stays above [thresholdBpm] for at least
/// [sustainFor]. A single high reading is not enough, because one bad
/// sample or a brief spike shouldn't trigger an alert.
class TachycardiaDetector {
  TachycardiaDetector({
    this.thresholdBpm = 100,
    this.sustainFor = const Duration(seconds: 10),
  });

  final int thresholdBpm;
  final Duration sustainFor;

  HeartRateState _state = HeartRateState.noData;
  DateTime? _aboveSince;

  HeartRateState get state => _state;

  /// When the current run of above-threshold readings started (null if none).
  DateTime? get aboveSince => _aboveSince;

  /// Feed one BPM reading taken at [time]. Returns the new state.
  HeartRateState addReading(int bpm, DateTime time) {
    if (bpm <= 0) {
      _aboveSince = null;
      _state = HeartRateState.noData;
    } else if (bpm <= thresholdBpm) {
      _aboveSince = null;
      _state = HeartRateState.normal;
    } else {
      _aboveSince ??= time;
      final highFor = time.difference(_aboveSince!);
      _state = highFor >= sustainFor
          ? HeartRateState.tachycardia
          : HeartRateState.elevated;
    }
    return _state;
  }

  void reset() {
    _aboveSince = null;
    _state = HeartRateState.noData;
  }
}
