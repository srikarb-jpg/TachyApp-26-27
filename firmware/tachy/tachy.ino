#include <Wire.h>
#include "MAX30105.h"     // SparkFun library, also works for MAX30102
#include <NimBLEDevice.h> // "NimBLE-Arduino" library: Bluetooth Low Energy

// ---------- Settings ----------
const int SAMPLE_HZ = 50;
const unsigned long SAMPLE_MS = 1000 / SAMPLE_HZ;
const float THRESH = 200;          // about 1/3 of your 600-count spikes
const long FINGER_MIN_IR = 50000;  // below this, no finger is on the sensor

const uint8_t MPU_ADDR = 0x68;     // MPU-6050 I2C address

MAX30105 ppg;

// ---------- Bluetooth (standard Heart Rate service) ----------
// The Flutter app looks for a device advertising service 0x180D
// (or named "TachyWatch") and reads BPM from characteristic 0x2A37.
const char* BLE_NAME = "TachyWatch";
NimBLEServer* bleServer = nullptr;
NimBLECharacteristic* hrChar = nullptr;

void setupBle() {
  NimBLEDevice::init(BLE_NAME);
  bleServer = NimBLEDevice::createServer();

  NimBLEService* hrService = bleServer->createService("180D");
  hrChar = hrService->createCharacteristic("2A37", NIMBLE_PROPERTY::NOTIFY);
  hrService->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(BLE_NAME);
  adv->addServiceUUID("180D");
  adv->start();
  // NimBLE restarts advertising by itself after the phone disconnects.
}

// Sends one Heart Rate Measurement: [flags = 0 (BPM is 1 byte), BPM].
// BPM 0 means "no reading" (no finger, or still measuring).
void sendBpm(int bpm) {
  if (bleServer == nullptr || bleServer->getConnectedCount() == 0) return;
  if (bpm < 0) bpm = 0;
  if (bpm > 255) bpm = 255;
  uint8_t packet[2] = {0x00, (uint8_t)bpm};
  hrChar->setValue(packet, 2);
  hrChar->notify();
}

// ---------- MPU-6050 register helpers ----------
void mpuWrite(uint8_t reg, uint8_t val) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);                 // which register
  Wire.write(val);                 // what to put in it
  Wire.endTransmission();
}

uint8_t mpuRead8(uint8_t reg) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(reg);                 // point at the register
  Wire.endTransmission(false);     // keep the bus, then read
  Wire.requestFrom(MPU_ADDR, (uint8_t)1);
  return Wire.read();
}

int16_t readWord() {
  uint8_t hi = Wire.read();        // high byte comes first
  uint8_t lo = Wire.read();
  return (int16_t)((hi << 8) | lo);
}

bool mpuReadAccel(float &ax, float &ay, float &az) {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);                // ACCEL_XOUT_H: start of accel data
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(MPU_ADDR, (uint8_t)6) != 6) return false;

  const float SCALE = 9.81 / 8192.0;   // +/-4 g range: 8192 counts = 1 g
  ax = readWord() * SCALE;
  ay = readWord() * SCALE;
  az = readWord() * SCALE;
  return true;
}

// ---------- Beat detector state ----------
float baseline = 0;
bool above = false;
bool fingerOn = false;
unsigned long lastBeat = 0;
float bpmAvg = 0;

void resetBeatDetector(long ir) {
  baseline = ir;
  above = false;
  lastBeat = 0;
  bpmAvg = 0;
}

void detectBeat(long ir, unsigned long now) {
  baseline += 0.02 * (ir - baseline);   // slow average = steady (DC) level
  float ac = ir - baseline;             // pulsing part only

  if (!above && ac > THRESH) {          // rising edge = a beat
    above = true;
    unsigned long dt = now - lastBeat;
    if (lastBeat == 0 || dt > 300) {    // ignore anything faster than 200 BPM
      if (lastBeat != 0 && dt < 2000) { // ignore gaps longer than 2 s
        float bpm = 60000.0 / dt;
        bpmAvg = (bpmAvg == 0) ? bpm : 0.8 * bpmAvg + 0.2 * bpm;
      }
      lastBeat = now;
    }
  } else if (above && ac < THRESH * 0.5) {
    above = false;                      // hysteresis: must drop before next beat
  }
}

void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);
  delay(100);

  // ---- MPU-6050 ----
  uint8_t who = mpuRead8(0x75);         // WHO_AM_I register
  Serial.print("MPU WHO_AM_I = 0x");
  Serial.println(who, HEX);
  if (who == 0x00 || who == 0xFF) {
    Serial.println("MPU not responding - check wiring");
    while (1) delay(10);
  }
  mpuWrite(0x6B, 0x00);   // PWR_MGMT_1: wake the chip up (it starts asleep)
  delay(100);
  mpuWrite(0x1C, 0x08);   // ACCEL_CONFIG: set +/-4 g range

  // ---- MAX30102 ----
  if (!ppg.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found - check wiring");
    while (1) delay(10);
  }
  ppg.setup();

  // ---- Bluetooth ----
  setupBle();
  Serial.print("Bluetooth advertising as ");
  Serial.println(BLE_NAME);

  Serial.println("Heart rate monitor started");
}

void loop() {
  static unsigned long lastSample = 0, lastPrint = 0;
  unsigned long now = millis();

  // ---- Read the heart rate sensor 50 times per second ----
  if (now - lastSample >= SAMPLE_MS) {
    lastSample = now;
    long ir = ppg.getIR();

    if (ir < FINGER_MIN_IR) {
      fingerOn = false;
    } else {
      if (!fingerOn) {
        fingerOn = true;
        resetBeatDetector(ir);
      }
      detectBeat(ir, now);
    }
  }

  // ---- Print and send results once per second ----
  if (now - lastPrint >= 1000) {
    lastPrint = now;

    if (!fingerOn) {
      Serial.println("Place your finger on the sensor");
      sendBpm(0);
      return;
    }

    if (lastBeat != 0 && now - lastBeat > 3000) {
      bpmAvg = 0;
    }

    float ax, ay, az;
    bool moving = false;
    if (mpuReadAccel(ax, ay, az)) {
      float mag = sqrt(ax * ax + ay * ay + az * az);
      moving = fabs(mag - 9.81) > 1.5;
    }

    Serial.print("BPM: ");
    if (bpmAvg == 0) Serial.print("measuring...");
    else             Serial.print(bpmAvg, 0);
    Serial.print(moving ? "  |  MOTION - reading unreliable" : "  |  still");
    Serial.println(bleServer->getConnectedCount() > 0 ? "  |  phone connected" : "");

    sendBpm((int)(bpmAvg + 0.5));       // 0 while still measuring
  }
}
