# TachyWatch: ESP32 + MAX30102 + MPU-6050 → BLE → Flutter

The data flows like this:

```
MAX30102 (PPG: IR + Red) ─┐
                          ├─ I2C ─> ESP32 ──BLE──> Flutter app (TachyApp)
MPU-6050 (accelerometer) ─┘          │               ├─ live PPG waveform
                                     │               ├─ BPM trend
                     beat detection, │               ├─ motion indicator
                     motion flag     │               └─ tachycardia alert
```

Files in this folder:
- `firmware/tachy_watch/tachy_watch.ino`: the ESP32 sketch
- `flutter_lib/services/tachy_watch_service.dart`: BLE client, packet parser and PPG filter for your existing Flutter app

---

## Step 1: Wire it on the breadboard (USB power only for now)

Both sensors use the same I2C bus and have different addresses (MAX30102 = `0x57`, MPU-6050 = `0x68`), so they share wires.

| Sensor pin | ESP32 DevKit pin |
|---|---|
| MAX30102 VIN, MPU-6050 VCC | 3V3 |
| MAX30102 GND, MPU-6050 GND | GND |
| MAX30102 SDA, MPU-6050 SDA | GPIO 21 |
| MAX30102 SCL, MPU-6050 SCL | GPIO 22 |
| MPU-6050 AD0 | GND |
| MAX30102 INT | GPIO 19 through your 4.7 kΩ pull-up to 3V3 (optional: the sketch polls the FIFO instead) |

Leave the LiPo and TP4056 out until Step 9. Power the board from USB while you develop.

## Step 2: Check each sensor on its own

1. Arduino IDE → Boards Manager → install **esp32 by Espressif**. Select **ESP32 Dev Module**.
2. Library Manager → install **SparkFun MAX3010x**, **Adafruit MPU6050** and **NimBLE-Arduino**.
3. Run the library examples first:
   - `File → Examples → SparkFun MAX3010x → Example4_HeartBeatPlotter`. Open **Tools → Serial Plotter**, rest a fingertip on the sensor, and you should see a pulsing waveform.
   - `File → Examples → Adafruit MPU6050 → basic_readings`. Tilt the board and watch the values change.
4. If a sensor isn't found, run an I2C scanner sketch. You should see `0x57` and `0x68`.

Do this before writing any app code. When the waveform looks wrong, the cause is almost always wiring, finger pressure or ambient light, not your code.

## Step 3: Flash the TachyWatch firmware

Open `firmware/tachy_watch/tachy_watch.ino` and upload it. It:
- reads the MAX30102 at **100 Hz** (IR + Red) and the MPU-6050 once per PPG sample
- detects beats on the device with SparkFun's `checkForBeat()` and averages the last 4 beats into a BPM
- flags **finger on sensor** (IR > 50 000) and **motion** (the spread of the acceleration magnitude over about 1 s)
- sends everything over BLE:

| Characteristic | Rate | Contents |
|---|---|---|
| `0x180D / 0x2A37` Heart Rate (standard) | 1 Hz | `[flags=0, bpm]`, the same format your old NanoPPG used |
| `a1c40002-…` RAW | 10 packets/s | `seq u16, count u8`, then 10 × `{ir u32, red u32, ax i16, ay i16, az i16}` (milli-g) |
| `a1c40003-…` VITALS | 1 Hz | `bpm u8, flags u8 (bit0 finger, bit1 motion), ibiMs u16` |

All values are little-endian. A RAW packet is 143 bytes, so it needs a BLE MTU bigger than the default 23. Android's `connect()` in flutter_blue_plus asks for 512, and iOS negotiates about 185 by itself.

Open Serial Monitor at 115200 to check that it works: you should get a `bpm=… finger=1 moving=0` line every second.

## Step 4: Check the BLE side without your app

Install **nRF Connect** (iOS or Android), scan for **TachyWatch**, connect, and subscribe to the three characteristics. You should see bytes updating. If they do, every later problem is in the app.

## Step 5: Add the service to your Flutter app

Your old app (`TachyApp/tachy_app_flutter`) already has the dependencies this needs: `flutter_blue_plus`, `fl_chart`, `provider` and `permission_handler`.

1. Copy `flutter_lib/services/tachy_watch_service.dart` into `lib/services/`.
2. In `lib/providers/ppg_provider.dart`, replace `BleConnectionService` with `TachyWatchService`:

```dart
import '../services/tachy_watch_service.dart';

late final TachyWatchService _watch;
final PpgFilter _ppgFilter = PpgFilter();

final List<VoltageDataPoint> _ppgWave = [];   // filtered PPG, 100 Hz
final List<VoltageDataPoint> _bpmTrend = [];  // 1 Hz
final List<VoltageDataPoint> _motion = [];    // |a| in g, 100 Hz
bool _fingerOn = false, _moving = false;
DateTime? _tachySince;

void _initBluetooth() {
  _watch = TachyWatchService(
    onStatusChanged: (s) { _connectionStatus = s; notifyListeners(); },
    onConnectionChanged: (c) { _isConnected = c; if (!c) _resetOnDisconnect(); notifyListeners(); },
    onSamples: _handleSamples,
    onVitals: _handleVitals,
  );
}

void _handleSamples(List<RawSample> samples) {
  // The 10 samples in a packet are 10 ms apart. Spread their timestamps backwards from "now".
  final now = DateTime.now();
  for (var i = 0; i < samples.length; i++) {
    final t = now.subtract(Duration(milliseconds: (samples.length - 1 - i) * 10));
    final s = samples[i];
    _ppgWave.add(VoltageDataPoint(t, _ppgFilter.process(s.ir)));
    _motion.add(VoltageDataPoint(t, math.sqrt(s.ax * s.ax + s.ay * s.ay + s.az * s.az)));
  }
  _trim(_ppgWave, 500);  // keep 5 s on screen
  _trim(_motion, 500);
  notifyListeners();     // about 10x/s, smooth enough for fl_chart
}

void _handleVitals(Vitals v) {
  _fingerOn = v.fingerOn;
  _moving = v.moving;
  _bpm = v.bpm.toDouble();
  _bpmTrend.add(VoltageDataPoint(DateTime.now(), _bpm));
  _trim(_bpmTrend, 300); // 5 minutes
  _updateTachy();
  notifyListeners();
}

void _trim(List l, int max) { if (l.length > max) l.removeRange(0, l.length - max); }
```

3. Call `_watch.startScanning()` from the place that used to call `_bluetoothService.startScanning()`.

## Step 6: Detect tachycardia so exercise doesn't trigger it

A single reading over 100 BPM doesn't count. The rule below needs the rate to stay high **while the user is still**, and that's the job the MPU-6050 does:

```dart
static const _sustain = Duration(seconds: 30);

void _updateTachy() {
  final high = _fingerOn && _bpm > kTachyBpmThreshold;   // 100 BPM
  if (!high) { _tachySince = null; _isTachy = false; return; }
  if (_moving) { _tachySince = null; return; }            // high HR while moving = probably exercise
  _tachySince ??= DateTime.now();
  _isTachy = DateTime.now().difference(_tachySince!) >= _sustain;
}
```

If you want "resting" to mean longer than about a second, keep a rolling history of `_moving` so the rule only applies when there has been, say, no motion for the last 60 s.

## Step 7: Draw the graphs

Your `VoltageGraph` widget already plots `List<VoltageDataPoint>` with fl_chart, so use it for all three:

```dart
VoltageGraph(voltageHistory: provider.ppgWave)   // live pulse waveform (last 5 s)
VoltageGraph(voltageHistory: provider.bpmTrend)  // BPM over the last 5 min
VoltageGraph(voltageHistory: provider.motion)    // motion; flat ≈ 1.0 g when still
```

Two changes to `VoltageGraph`:
- Make `peakThreshold` (2.8) a constructor parameter. Pass `null` for the waveform, `100` for the BPM chart so the tachy line shows, and `null` for motion.
- For the BPM chart, set the y-axis to a fixed 40–180 range so it doesn't rescale every second.

Add a status row too. Show **No finger** when `!fingerOn` and **Motion: readings may be noisy** when `moving`, and dim or hide the waveform while `!fingerOn`.

Important: the old app never drew a real waveform. `_handleDirectBpm` turned each BPM number into a made-up voltage (`_bpmToVoltage`). The RAW stream gives you the actual PPG signal.

## Step 8: Log and validate

1. Save CSV files (add `path_provider` and `share_plus`): `timestamp, ir, red, ax, ay, az` from `onSamples`, plus `timestamp, bpm, finger, moving` from `onVitals`.
2. Record at the same time as a reference device, such as a fingertip pulse oximeter or a commercial smartwatch: at rest, after climbing stairs, and while waving your arm.
3. Compare the BPMs. If the on-device `checkForBeat()` isn't accurate enough, compute BPM in the app from the RAW IR stream instead (band-pass 0.5–4 Hz, then peak detection). Your existing `detectTachycardia` and AFib logic can run on those peak timestamps.
4. Check `droppedPackets` on the service. It should stay near 0.

## Step 9: Battery power (after everything else works)

- **Never connect the LiPo straight to the 3V3 pin.** A full cell is 4.2 V.
- Feeding the LiPo into the DevKit's 5V/VIN pin will brown out. Its AMS1117 regulator needs about 1 V of headroom, and a LiPo spends most of its life at 3.7 V.
- What works: **LiPo → TP4056 with protection** (the board with the DW01 chip and OUT+/OUT− pads) **→ a low-dropout 3.3 V regulator** (for example MCP1700-3302 or HT7333, under $1) **→ 3V3 pin**.
- Battery life: with BLE streaming the ESP32 draws about 80–130 mA, so a 150 mAh cell lasts roughly 1–1.5 h and a 500 mAh cell about 4–5 h. To stretch it, stop sending RAW when no one is watching the live graph (send VITALS only) and lower the LED brightness.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| BPM jumps around | Finger pressure too light or too hard, ambient light, or motion. Try `ledBrightness` values 0x1F–0x7F. |
| `finger` always 0 | Your board's IR level is different. Print `ir` and adjust the 50 000 threshold. |
| RAW packets cut short in the app | MTU didn't negotiate. Log `device.mtuNow`. It must be ≥ 146. |
| App can't find the device | Android needs Bluetooth Scan/Connect permissions, which `permission_handler` already covers. On iOS, check the `NSBluetoothAlwaysUsageDescription` key in Info.plist. |
| ESP32 resets when BLE connects | Power problem. Use a better USB cable or port, or see Step 9. |

> This is a prototype for a research or class project, not a medical device. PPG at the wrist or finger can't diagnose arrhythmias. Confirm against an ECG before you draw any conclusions.
