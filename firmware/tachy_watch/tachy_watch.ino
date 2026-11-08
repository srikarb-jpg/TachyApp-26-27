// tachy_watch.ino — ESP32 + MAX30102 + MPU-6050 -> BLE
//
// Libraries (Arduino Library Manager):
//   - "SparkFun MAX3010x Pulse and Proximity Sensor Library"  (works for MAX30102)
//   - "Adafruit MPU6050"  (pulls in Adafruit Unified Sensor + BusIO)
//   - "NimBLE-Arduino"  (v2.x)
// Board: "ESP32 Dev Module" (Boards Manager: "esp32" by Espressif)
//
// Wiring (both sensors share one I2C bus, powered from 3V3):
//   MAX30102 VIN -> 3V3   GND -> GND   SDA -> GPIO21   SCL -> GPIO22   INT -> GPIO19 (optional, 4.7k pull-up to 3V3)
//   MPU-6050 VCC -> 3V3   GND -> GND   SDA -> GPIO21   SCL -> GPIO22   AD0 -> GND (addr 0x68)
//
// BLE layout:
//   Heart Rate Service 0x180D / 0x2A37 : standard BPM, 1 Hz   (same as your old NanoPPG, so the old app still works)
//   Custom "Tachy" service:
//     RAW    char : 10 samples per notify (IR, Red, accel x/y/z), 100 Hz total
//     VITALS char : bpm, flags (finger, motion), last beat interval, 1 Hz

#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <NimBLEDevice.h>

#define SDA_PIN 21
#define SCL_PIN 22

static const char* DEVICE_NAME = "TachyWatch";

#define HR_SERVICE_UUID     "180D"
#define HR_MEAS_UUID        "2A37"
#define TACHY_SERVICE_UUID  "a1c40001-7f3e-4b8e-9c2d-5e6f7a8b9c0d"
#define RAW_CHAR_UUID       "a1c40002-7f3e-4b8e-9c2d-5e6f7a8b9c0d"
#define VITALS_CHAR_UUID    "a1c40003-7f3e-4b8e-9c2d-5e6f7a8b9c0d"

// ---------- Packet formats (little-endian, mirrored in the Dart parser) ----------
#define SAMPLES_PER_PACKET 10
struct __attribute__((packed)) Sample {
  uint32_t ir;        // MAX30102 IR count (18-bit)
  uint32_t red;       // MAX30102 Red count (18-bit)
  int16_t  ax, ay, az; // acceleration in milli-g
};                     // 14 bytes
struct __attribute__((packed)) RawPacket {
  uint16_t seq;        // increments every packet -> app can detect drops
  uint8_t  count;      // number of valid samples
  Sample   s[SAMPLES_PER_PACKET];
};                     // 3 + 140 = 143 bytes (needs MTU >= 146)
struct __attribute__((packed)) VitalsPacket {
  uint8_t  bpm;        // 0 = unknown
  uint8_t  flags;      // bit0 = finger on sensor, bit1 = motion detected
  uint16_t ibiMs;      // last inter-beat interval in ms
};

MAX30105 ppg;
Adafruit_MPU6050 mpu;

NimBLECharacteristic* hrChar;
NimBLECharacteristic* rawChar;
NimBLECharacteristic* vitalsChar;
volatile bool clientConnected = false;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    clientConnected = true;
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    clientConnected = false;
    NimBLEDevice::startAdvertising();
  }
};

// ---------- Heart-rate state ----------
const uint8_t RATE_SIZE = 4;
uint8_t rates[RATE_SIZE];
uint8_t rateIdx = 0, rateCount = 0;
uint32_t lastBeatMs = 0;
uint16_t lastIbiMs = 0;
uint8_t avgBpm = 0;
bool fingerOn = false;

// ---------- Motion state: variance of |a| over ~1 s ----------
float motionMean = 1.0f, motionVar = 0.0f;
bool moving = false;

RawPacket pkt;
uint16_t seq = 0;
uint32_t lastVitalsMs = 0;

void setupBle() {
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* hrSvc = server->createService(HR_SERVICE_UUID);
  hrChar = hrSvc->createCharacteristic(HR_MEAS_UUID, NIMBLE_PROPERTY::NOTIFY);

  NimBLEService* tachySvc = server->createService(TACHY_SERVICE_UUID);
  rawChar    = tachySvc->createCharacteristic(RAW_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY);
  vitalsChar = tachySvc->createCharacteristic(VITALS_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ);

  hrSvc->start();
  tachySvc->start();

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->setName(DEVICE_NAME);
  adv->addServiceUUID(HR_SERVICE_UUID);
  adv->start();
}

void setup() {
  Serial.begin(115200);
  Wire.begin(SDA_PIN, SCL_PIN);
  Wire.setClock(400000);

  if (!ppg.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found - check wiring (addr 0x57)");
    while (true) delay(1000);
  }
  // ledBrightness, sampleAverage, ledMode(2=Red+IR), sampleRate, pulseWidth, adcRange
  // 400 Hz / average 4 = 100 samples per second out of the FIFO
  ppg.setup(0x1F, 4, 2, 400, 411, 4096);

  if (!mpu.begin(0x68, &Wire)) {
    Serial.println("MPU-6050 not found - check wiring (addr 0x68)");
    while (true) delay(1000);
  }
  mpu.setAccelerometerRange(MPU6050_RANGE_4_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

  setupBle();
  Serial.println("TachyWatch ready, advertising...");
}

void processBeat(uint32_t ir, uint32_t now) {
  fingerOn = ir > 50000;  // tune for your board/skin; below this = no finger
  if (!fingerOn) { rateCount = 0; avgBpm = 0; return; }

  if (checkForBeat(ir)) {
    uint32_t delta = now - lastBeatMs;
    lastBeatMs = now;
    float bpm = 60000.0f / delta;
    if (bpm > 30 && bpm < 220) {           // physiological range
      lastIbiMs = delta;
      rates[rateIdx++ % RATE_SIZE] = (uint8_t)bpm;
      if (rateCount < RATE_SIZE) rateCount++;
      uint16_t sum = 0;
      for (uint8_t i = 0; i < rateCount; i++) sum += rates[i];
      avgBpm = sum / rateCount;
    }
  }
}

void processMotion(float axG, float ayG, float azG) {
  float mag = sqrtf(axG * axG + ayG * ayG + azG * azG);
  const float alpha = 0.01f;               // ~1 s time constant at 100 Hz
  float d = mag - motionMean;
  motionMean += alpha * d;
  motionVar = (1 - alpha) * (motionVar + alpha * d * d);
  moving = sqrtf(motionVar) > 0.05f;       // > 0.05 g std-dev = moving (tune it)
}

void loop() {
  ppg.check();  // pull new samples from the MAX30102 FIFO
  while (ppg.available()) {
    uint32_t now = millis();
    uint32_t red = ppg.getFIFORed();
    uint32_t ir  = ppg.getFIFOIR();
    ppg.nextSample();

    sensors_event_t a, g, t;
    mpu.getEvent(&a, &g, &t);
    float axG = a.acceleration.x / 9.80665f;
    float ayG = a.acceleration.y / 9.80665f;
    float azG = a.acceleration.z / 9.80665f;

    processBeat(ir, now);
    processMotion(axG, ayG, azG);

    // Uncomment to see the raw signal in Tools > Serial Plotter (step 2 of the guide)
    // Serial.printf("ir:%u,red:%u,bpm:%u\n", ir, red, avgBpm);

    Sample& s = pkt.s[pkt.count++];
    s.ir = ir; s.red = red;
    s.ax = (int16_t)(axG * 1000); s.ay = (int16_t)(ayG * 1000); s.az = (int16_t)(azG * 1000);

    if (pkt.count == SAMPLES_PER_PACKET) {
      pkt.seq = seq++;
      if (clientConnected) {
        rawChar->setValue((uint8_t*)&pkt, sizeof(pkt));
        rawChar->notify();
      }
      pkt.count = 0;
    }
  }

  uint32_t now = millis();
  if (now - lastVitalsMs >= 1000) {
    lastVitalsMs = now;
    VitalsPacket v{avgBpm, (uint8_t)((fingerOn ? 1 : 0) | (moving ? 2 : 0)), lastIbiMs};
    uint8_t hr[2] = {0x00, avgBpm};        // 0x2A37: flags=0 (uint8 BPM), BPM
    if (clientConnected) {
      vitalsChar->setValue((uint8_t*)&v, sizeof(v));
      vitalsChar->notify();
      hrChar->setValue(hr, 2);
      hrChar->notify();
    }
    Serial.printf("bpm=%u finger=%d moving=%d ibi=%u\n", avgBpm, fingerOn, moving, lastIbiMs);
  }
}
