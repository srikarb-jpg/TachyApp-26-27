//
// tachy_watch_service.dart
// Drop into tachy_app_flutter/lib/services/ next to bluetooth_service.dart.
//
// Connects to the ESP32 "TachyWatch" and decodes the RAW + VITALS
// characteristics defined in firmware/tachy_watch/tachy_watch.ino.
//

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class RawSample {
  final int ir;
  final int red;
  final double ax, ay, az; // in g
  const RawSample(this.ir, this.red, this.ax, this.ay, this.az);
}

class Vitals {
  final int bpm;
  final bool fingerOn;
  final bool moving;
  final int ibiMs;
  const Vitals(this.bpm, this.fingerOn, this.moving, this.ibiMs);
}

/// Parses one RAW notification: [seq u16][count u8][count x 14-byte samples].
List<RawSample> parseRawPacket(List<int> value) {
  if (value.length < 3) return const [];
  final bd = ByteData.sublistView(Uint8List.fromList(value));
  final count = bd.getUint8(2);
  final out = <RawSample>[];
  for (var i = 0; i < count; i++) {
    final o = 3 + i * 14;
    if (o + 14 > value.length) break; // truncated (MTU too small)
    out.add(RawSample(
      bd.getUint32(o, Endian.little),
      bd.getUint32(o + 4, Endian.little),
      bd.getInt16(o + 8, Endian.little) / 1000.0,
      bd.getInt16(o + 10, Endian.little) / 1000.0,
      bd.getInt16(o + 12, Endian.little) / 1000.0,
    ));
  }
  return out;
}

/// Parses one VITALS notification: [bpm u8][flags u8][ibiMs u16].
Vitals? parseVitals(List<int> value) {
  if (value.length < 4) return null;
  final bd = ByteData.sublistView(Uint8List.fromList(value));
  final flags = bd.getUint8(1);
  return Vitals(bd.getUint8(0), flags & 0x01 != 0, flags & 0x02 != 0,
      bd.getUint16(2, Endian.little));
}

class TachyWatchService {
  static const String deviceName = "TachyWatch";
  static final Guid tachyService = Guid("a1c40001-7f3e-4b8e-9c2d-5e6f7a8b9c0d");
  static final Guid rawChar = Guid("a1c40002-7f3e-4b8e-9c2d-5e6f7a8b9c0d");
  static final Guid vitalsChar = Guid("a1c40003-7f3e-4b8e-9c2d-5e6f7a8b9c0d");

  final void Function(String) onStatusChanged;
  final void Function(bool) onConnectionChanged;
  final void Function(List<RawSample>) onSamples;
  final void Function(Vitals) onVitals;

  TachyWatchService({
    required this.onStatusChanged,
    required this.onConnectionChanged,
    required this.onSamples,
    required this.onVitals,
  });

  BluetoothDevice? _device;
  StreamSubscription? _scanSub;
  final List<StreamSubscription> _charSubs = [];
  int? _lastSeq;
  int droppedPackets = 0;

  Future<void> startScanning() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      onStatusChanged("Bluetooth is off");
      return;
    }
    onStatusChanged("Scanning for $deviceName...");
    _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        if (name == deviceName) {
          await FlutterBluePlus.stopScan();
          await _scanSub?.cancel();
          await _connect(r.device);
          return;
        }
      }
    });
    await FlutterBluePlus.startScan(
      withNames: [deviceName],
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> _connect(BluetoothDevice device) async {
    try {
      _device = device;
      onStatusChanged("Connecting...");
      // On Android, connect() requests MTU 512 by default; iOS negotiates ~185
      // automatically. Both are big enough for the 143-byte RAW packet.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
      );
      onConnectionChanged(true);

      device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          onConnectionChanged(false);
          onStatusChanged("Disconnected");
        }
      });

      final services = await device.discoverServices();
      final svc = services.firstWhere((s) => s.serviceUuid == tachyService);
      for (final c in svc.characteristics) {
        if (c.uuid == rawChar) {
          await c.setNotifyValue(true);
          _charSubs.add(c.onValueReceived.listen(_handleRaw));
        } else if (c.uuid == vitalsChar) {
          await c.setNotifyValue(true);
          _charSubs.add(c.onValueReceived.listen((v) {
            final vit = parseVitals(v);
            if (vit != null) onVitals(vit);
          }));
        }
      }
      onStatusChanged("Receiving data (MTU ${device.mtuNow})");
    } catch (e) {
      onConnectionChanged(false);
      onStatusChanged("Connection failed: $e");
    }
  }

  void _handleRaw(List<int> value) {
    if (value.length >= 2) {
      final seq = value[0] | (value[1] << 8);
      if (_lastSeq != null) {
        final gap = (seq - _lastSeq! - 1) & 0xFFFF;
        droppedPackets += gap;
      }
      _lastSeq = seq;
    }
    onSamples(parseRawPacket(value));
  }

  Future<void> disconnect() async {
    for (final s in _charSubs) {
      await s.cancel();
    }
    _charSubs.clear();
    await _device?.disconnect();
    _device = null;
  }
}

/// Turns raw IR counts (~100k with a tiny pulse on top) into a clean,
/// centered waveform for the graph: remove DC, invert, light low-pass.
class PpgFilter {
  double _dc = 0;
  double _lp = 0;
  bool _init = false;

  double process(int ir) {
    final x = ir.toDouble();
    if (!_init) {
      _dc = x;
      _lp = 0;
      _init = true;
    }
    _dc = 0.99 * _dc + 0.01 * x; // ~1 s DC tracker at 100 Hz
    final ac = _dc - x; // invert: blood volume up = signal up
    _lp = 0.7 * _lp + 0.3 * ac; // smooth out high-frequency noise
    return _lp;
  }

  void reset() => _init = false;
}
