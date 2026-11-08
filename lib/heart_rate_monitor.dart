// heart_rate_monitor.dart
//
// Finds the sensor over Bluetooth Low Energy, connects, subscribes to the
// standard Heart Rate Measurement characteristic, and keeps the latest BPM
// and tachycardia state. The UI listens to it (it's a ChangeNotifier).
//
// The ESP32 firmware must expose the standard Heart Rate Service:
//   service 0x180D, characteristic 0x2A37 (notify), value = [flags, bpm].

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'heart_rate.dart';

class HeartRateMonitor extends ChangeNotifier {
  static final Guid heartRateService = Guid('180D');
  static final Guid heartRateMeasurement = Guid('2A37');

  /// Device names to accept even if the advertisement doesn't list 0x180D.
  /// Add your ESP32's name here if it isn't found.
  static const List<String> knownDeviceNames = ['TachyWatch', 'NanoPPG'];

  static const Duration scanTimeout = Duration(seconds: 10);

  final TachycardiaDetector detector = TachycardiaDetector();

  String status = 'Not connected';
  bool busy = false;
  bool connected = false;
  String? deviceName;
  int? bpm;
  DateTime? lastReading;

  HeartRateState get state => detector.state;

  BluetoothDevice? _device;
  StreamSubscription<BluetoothConnectionState>? _connectionSub;

  Future<void> connect() async {
    if (busy || connected) return;
    busy = true;
    _setStatus('Checking Bluetooth...');

    try {
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
      if (adapter != BluetoothAdapterState.on) {
        _setStatus('Bluetooth is off. Turn it on and try again.');
        return;
      }

      _setStatus('Scanning for heart-rate sensor...');
      final result = await _scanForSensor();
      if (result == null) {
        _setStatus('No sensor found. Is the ESP32 powered on and advertising?');
        return;
      }

      final device = result.device;
      _device = device;
      deviceName = result.advertisementData.advName.isNotEmpty
          ? result.advertisementData.advName
          : device.remoteId.str;
      _setStatus('Connecting to $deviceName...');

      // License.nonprofit: flutter_blue_plus is free for personal and
      // educational use. A for-profit product needs a commercial license.
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );

      _connectionSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) _onDisconnected();
      });

      final characteristic = await _findHeartRateCharacteristic(device);
      if (characteristic == null) {
        _setStatus('Connected, but $deviceName has no Heart Rate service (0x180D/0x2A37).');
        await device.disconnect();
        return;
      }

      await characteristic.setNotifyValue(true);
      final dataSub = characteristic.onValueReceived.listen(_onData);
      device.cancelWhenDisconnected(dataSub);

      connected = true;
      _setStatus('Connected to $deviceName');
    } catch (e) {
      _setStatus('Error: $e');
      try {
        await _device?.disconnect();
      } catch (_) {}
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
  }

  /// Scans until it sees a device advertising the Heart Rate Service, or
  /// one of [knownDeviceNames]. Returns null after [scanTimeout].
  Future<ScanResult?> _scanForSensor() async {
    final found = Completer<ScanResult?>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final ad = r.advertisementData;
        final hasHrService = ad.serviceUuids.contains(heartRateService);
        final hasKnownName = knownDeviceNames.contains(ad.advName);
        if ((hasHrService || hasKnownName) && !found.isCompleted) {
          found.complete(r);
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: scanTimeout);
      return await found.future.timeout(scanTimeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<BluetoothCharacteristic?> _findHeartRateCharacteristic(
      BluetoothDevice device) async {
    final services = await device.discoverServices();
    for (final service in services) {
      if (service.serviceUuid != heartRateService) continue;
      for (final c in service.characteristics) {
        if (c.characteristicUuid == heartRateMeasurement) return c;
      }
    }
    return null;
  }

  void _onData(List<int> bytes) {
    final value = parseHeartRateMeasurement(bytes);
    if (value == null) return;
    final now = DateTime.now();
    bpm = value;
    lastReading = now;
    detector.addReading(value, now);
    notifyListeners();
  }

  void _onDisconnected() {
    final wasConnected = connected;
    _connectionSub?.cancel();
    _connectionSub = null;
    _device = null;
    connected = false;
    bpm = null;
    lastReading = null;
    detector.reset();
    // Keep an error message from connect() instead of overwriting it.
    if (wasConnected) {
      _setStatus('Disconnected');
    } else {
      notifyListeners();
    }
  }

  void _setStatus(String s) {
    status = s;
    debugPrint('[HeartRateMonitor] $s');
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _device?.disconnect();
    super.dispose();
  }
}
