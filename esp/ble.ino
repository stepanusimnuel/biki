#include "HX711.h"

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include <ESP32Servo.h>

// ===================================================
// BLE
// ===================================================

#define DEVICE_NAME "ESP32-Sensor"

#define SERVICE_UUID      "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define SENSOR_CHAR_UUID  "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
#define COMMAND_CHAR_UUID "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

BLECharacteristic *sensorCharacteristic;
BLECharacteristic *commandCharacteristic;

bool bleConnected = false;

// ===================================================
// SERVO
// ===================================================

// Servo penyapu jeruk.
const int SERVO_15_PIN = 15;

// Servo pembuat jalur.
const int SERVO_9_PIN = 9;
const int SERVO_13_PIN = 13;

const int SERVO_MIN_US = 500;
const int SERVO_MAX_US = 2400;

const int SERVO_9_POSISI_AWAL = 120;
const int SERVO_15_POSISI_AWAL = 90;
const int SERVO_13_POSISI_AWAL = 120;

const int SERVO_15_SAPU = 0;

const int POSISI_1 = 30;
const int POSISI_2 = 0;

// Total waktu jeruk melalui bidang miring.
const unsigned long WAKTU_PROSES_MS = 2500;

// Kecepatan servo:
// angka lebih besar = lebih lambat.
const int DELAY_PER_DERAJAT_MS = 3;

Servo servo15;
Servo servo9;
Servo servo13;

int servo15Position = SERVO_15_POSISI_AWAL;
int servo9Position = SERVO_9_POSISI_AWAL;
int servo13Position = SERVO_13_POSISI_AWAL;

// ===================================================
// BLE COMMAND
//
// iPhone mengirim satu byte:
//
// 1 = Grade A
// 2 = Grade B
// 3 = Grade C
// 4 = Grade Edible
// 5 = Grade Reject
// ===================================================

const uint8_t CMD_GRADE_A = 1;
const uint8_t CMD_GRADE_B = 2;
const uint8_t CMD_GRADE_C = 3;
const uint8_t CMD_GRADE_EDIBLE = 4;
const uint8_t CMD_GRADE_REJECT = 5;

volatile uint8_t pendingCommand = 0;

// ===================================================
// HX711 + LOAD CELL
// ===================================================

const int LOADCELL_DOUT_PIN = 10;
const int LOADCELL_SCK_PIN = 8;

const float HX_A = 0.00233f;
const float HX_B = 1216.37f;

HX711 scale;

// ===================================================
// TCS3200
// ===================================================

const int S0 = 4;
const int S1 = 5;
const int S2 = 6;
const int S3 = 7;
const int OUT_PIN = 11;

enum ColorCode : uint8_t {
  UNKNOWN = 0,
  RED,
  ORANGE,
  YELLOW,
  GREEN,
  BLUE,
  BLACK,
  WHITE
};

struct ColorReference {
  ColorCode code;
  const char *name;
  uint16_t rawR;
  uint16_t rawG;
  uint16_t rawB;
};

ColorReference references[] = {
  {RED,    "MERAH",  117, 295, 234},
  {ORANGE, "ORANGE",  83, 178, 181},
  {YELLOW, "KUNING",  74, 104, 145},
  {GREEN,  "HIJAU",  211, 154, 183},
  {BLUE,   "BIRU",   253, 143,  94},
  {BLACK,  "HITAM",  485, 487, 411},
  {WHITE,  "PUTIH",   73,  72,  57}
};

const int COLOR_COUNT = sizeof(references) / sizeof(references[0]);

// ===================================================
// BLE CALLBACK
// ===================================================

class SensorServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) {
    bleConnected = true;
    Serial.println("iPhone terhubung lewat BLE.");
  }

  void onDisconnect(BLEServer *server) {
    bleConnected = false;
    Serial.println("iPhone terputus.");

    delay(300);
    BLEDevice::startAdvertising();
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    String value = characteristic->getValue();

    if (value.length() == 0) {
      return;
    }

    pendingCommand = (uint8_t)value.charAt(0);

    Serial.print("Grade command diterima: ");
    Serial.println(pendingCommand);
  }
};

// ===================================================
// SERVO FUNCTION
// ===================================================

void writeServo(Servo &servo, int angle) {
  servo.write(constrain(angle, 0, 180));
}

void moveServoSmooth(
  Servo &servo,
  int &currentPosition,
  int targetPosition
) {
  targetPosition = constrain(targetPosition, 0, 180);

  if (targetPosition > currentPosition) {
    for (int angle = currentPosition; angle <= targetPosition; angle++) {
      writeServo(servo, angle);
      delay(DELAY_PER_DERAJAT_MS);
      Serial.println(currentPosition);
    }
  } else {
    for (int angle = currentPosition; angle >= targetPosition; angle--) {
      writeServo(servo, angle);
      delay(DELAY_PER_DERAJAT_MS);
      Serial.println(currentPosition);
    }
  }

  currentPosition = targetPosition;
}

void resetAllServo() {
  moveServoSmooth(
    servo15,
    servo15Position,
    SERVO_15_POSISI_AWAL
  );

  moveServoSmooth(
    servo9,
    servo9Position,
    SERVO_9_POSISI_AWAL
  );

  moveServoSmooth(
    servo13,
    servo13Position,
    SERVO_13_POSISI_AWAL
  );
}

// Atur jalur lebih dahulu, baru servo 15 menyapu jeruk.
void jalankanGrade(
  int servo9Target,
  int servo13Target,
  const char *gradeName
) {
  Serial.print("Grade ");
  Serial.println(gradeName);

  // Setelah ESP menerima grade dari iPhone,
  // beri waktu 500 ms sebelum mengubah jalur.
  delay(500);

  // 1. Siapkan jalur grade.
  moveServoSmooth(
    servo9,
    servo9Position,
    servo9Target
  );

  moveServoSmooth(
    servo13,
    servo13Position,
    servo13Target
  );

  // 2. Pastikan jalur sudah terbentuk.
  delay(500);

  // 3. Sapu jeruk.
  moveServoSmooth(
    servo15,
    servo15Position,
    SERVO_15_SAPU
  );

  // 4. Jeruk melewati jalur.
  delay(3000);

  // 5. Semua servo kembali ke awal.
  resetAllServo();

  Serial.println("Siklus selesai. Semua servo kembali ke nol.");
}

void processCommand() {
  if (pendingCommand == 0) {
    return;
  }

  uint8_t command = pendingCommand;
  pendingCommand = 0;

  switch (command) {
    case CMD_GRADE_A:
      // Servo 13 posisi 2, servo 9 awal.
      jalankanGrade(SERVO_9_POSISI_AWAL, POSISI_1, "A");
      break;

    case CMD_GRADE_B:
      // Servo 13 posisi 1, servo 9 awal.
      jalankanGrade(SERVO_9_POSISI_AWAL, POSISI_2, "B");
      break;

    case CMD_GRADE_C:
      // Servo 13 awal, servo 9 posisi 1.
      jalankanGrade(POSISI_1, SERVO_13_POSISI_AWAL, "C");
      break;

    case CMD_GRADE_EDIBLE:
      // Servo 13 awal, servo 9 posisi 2.
      jalankanGrade(POSISI_2, SERVO_13_POSISI_AWAL, "D");
      break;

    case CMD_GRADE_REJECT:
      // Semua servo awal, tetapi servo 15 tetap menyapu jeruk.
      jalankanGrade(SERVO_9_POSISI_AWAL, SERVO_13_POSISI_AWAL, "E");
      break;

    default:
      Serial.println("Command grade tidak dikenal.");
      break;
  }
}

// ===================================================
// TCS3200
// ===================================================

unsigned long readFilter(bool s2Value, bool s3Value) {
  digitalWrite(S2, s2Value);
  digitalWrite(S3, s3Value);

  delay(10);

  unsigned long total = 0;
  int validSamples = 0;

  for (int i = 0; i < 20; i++) {
    unsigned long pulse = pulseIn(OUT_PIN, LOW, 100000);

    if (pulse > 0) {
      total += pulse;
      validSamples++;
    }
  }

  return validSamples > 0 ? total / validSamples : 0;
}

float colorDistance(
  uint16_t r,
  uint16_t g,
  uint16_t b,
  const ColorReference &reference
) {
  float dr = (float)r - reference.rawR;
  float dg = (float)g - reference.rawG;
  float db = (float)b - reference.rawB;

  return sqrtf(dr * dr + dg * dg + db * db);
}

ColorCode detectColor(uint16_t r, uint16_t g, uint16_t b) {
  float bestDistance = 999999.0f;
  ColorCode bestColor = UNKNOWN;

  for (int i = 0; i < COLOR_COUNT; i++) {
    float distance = colorDistance(r, g, b, references[i]);

    if (distance < bestDistance) {
      bestDistance = distance;
      bestColor = references[i].code;
    }
  }

  return bestColor;
}

const char *colorName(ColorCode code) {
  switch (code) {
    case RED:    return "MERAH";
    case ORANGE: return "ORANGE";
    case YELLOW: return "KUNING";
    case GREEN:  return "HIJAU";
    case BLUE:   return "BIRU";
    case BLACK:  return "HITAM";
    case WHITE:  return "PUTIH";
    default:     return "TIDAK DIKENAL";
  }
}

// ===================================================
// BLE DATA
// Paket 12 byte, little-endian:
//
// [0-3]  berat ×100 gram, Int32
// [4-5]  RAW R, UInt16
// [6-7]  RAW G, UInt16
// [8-9]  RAW B, UInt16
// [10]   kode warna
// [11]   status
// ===================================================

void notifySensorData(
  float weightG,
  uint16_t rawR,
  uint16_t rawG,
  uint16_t rawB,
  ColorCode colorCode,
  bool hxReady,
  bool colorReady
) {
  int32_t weight = (int32_t)roundf(weightG * 100.0f);
  uint32_t packedWeight = (uint32_t)weight;

  uint8_t packet[12];

  packet[0] = packedWeight & 0xFF;
  packet[1] = (packedWeight >> 8) & 0xFF;
  packet[2] = (packedWeight >> 16) & 0xFF;
  packet[3] = (packedWeight >> 24) & 0xFF;

  packet[4] = rawR & 0xFF;
  packet[5] = rawR >> 8;

  packet[6] = rawG & 0xFF;
  packet[7] = rawG >> 8;

  packet[8] = rawB & 0xFF;
  packet[9] = rawB >> 8;

  packet[10] = (uint8_t)colorCode;

  packet[11] = 0;

  if (hxReady) {
    packet[11] |= 0x01;
  }

  if (colorReady) {
    packet[11] |= 0x02;
  }

  sensorCharacteristic->setValue(packet, sizeof(packet));

  if (bleConnected) {
    sensorCharacteristic->notify();
  }
}

// ===================================================
// SETUP
// ===================================================

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Servo
  servo15.attach(SERVO_15_PIN, SERVO_MIN_US, SERVO_MAX_US);
  servo9.attach(SERVO_9_PIN, SERVO_MIN_US, SERVO_MAX_US);
  servo13.attach(SERVO_13_PIN, SERVO_MIN_US, SERVO_MAX_US);

  writeServo(servo15, SERVO_15_POSISI_AWAL);
  writeServo(servo9, SERVO_9_POSISI_AWAL);
  writeServo(servo13, SERVO_13_POSISI_AWAL);

  resetAllServo();

  delay(800);

  // TCS3200
  pinMode(S0, OUTPUT);
  pinMode(S1, OUTPUT);
  pinMode(S2, OUTPUT);
  pinMode(S3, OUTPUT);
  pinMode(OUT_PIN, INPUT);

  digitalWrite(S0, LOW);
  digitalWrite(S1, HIGH);

  // HX711
  scale.begin(LOADCELL_DOUT_PIN, LOADCELL_SCK_PIN);

  if (!scale.wait_ready_timeout(3000)) {
    Serial.println("HX711 tidak terdeteksi.");

    while (true) {
      delay(1000);
    }
  }

  // BLE
  BLEDevice::init(DEVICE_NAME);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new SensorServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  sensorCharacteristic = service->createCharacteristic(
    SENSOR_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );

  sensorCharacteristic->addDescriptor(new BLE2902());

  commandCharacteristic = service->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );

  commandCharacteristic->setCallbacks(
    new CommandCallbacks()
  );

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);

  BLEDevice::startAdvertising();

  Serial.println("BLE aktif: ESP32-Sensor");
  Serial.println("Sistem siap.");
}

// ===================================================
// LOOP
// ===================================================

void loop() {
  processCommand();

  uint16_t rawR = (uint16_t)readFilter(LOW, LOW);
  processCommand();

  uint16_t rawB = (uint16_t)readFilter(LOW, HIGH);
  processCommand();

  uint16_t rawG = (uint16_t)readFilter(HIGH, HIGH);
  processCommand();

  bool colorReady = rawR > 0 && rawG > 0 && rawB > 0;
  ColorCode colorCode = UNKNOWN;

  if (colorReady) {
    colorCode = detectColor(rawR, rawG, rawB);
  }

  bool hxReady = scale.wait_ready_timeout(1000);
  float weightG = 0;

  if (hxReady) {
    long rawValue = scale.read_average(30);

    weightG = HX_A * (float)rawValue + HX_B;

    if (weightG <= 0) {
      weightG = 0;
    }
  }

  notifySensorData(
    weightG,
    rawR,
    rawG,
    rawB,
    colorCode,
    hxReady,
    colorReady
  );

  Serial.print("Berat: ");
  Serial.print(weightG, 2);

  Serial.print(" g | RAW: (");
  Serial.print(rawR);
  Serial.print(", ");
  Serial.print(rawG);
  Serial.print(", ");
  Serial.print(rawB);

  Serial.print(") | Warna: ");
  Serial.println(colorName(colorCode));

  delay(10);
}