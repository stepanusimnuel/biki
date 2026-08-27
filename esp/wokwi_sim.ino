/*
  HaloBiki Grading Assistant — Wokwi Simulation Sketch
  Target: Arduino Nano RP2040 Connect (wokwi-nano-rp2040-connect)

  DESIGN (v5 — BLE added, app-side grading is authoritative):
  - 1 potentiometer simulates the TCS34725 color sensor (maturity %).
  - The HX711 weight IS live-controllable — Wokwi shows a "Pressure"
    slider (in kg) when you click the part during simulation. This
    isn't documented on Wokwi's own docs page (which only mentions
    Automation Scenarios), so it's easy to miss — but it's real.
  - IMPORTANT CALIBRATION NOTE: Wokwi's simulated HX711 does NOT behave
    like a real chip's raw ADC output. Per Wokwi's docs, the "5kg" part
    type produces raw readings from 0-2100 across the full 0-5000g
    range — a clean linear mapping, nothing like a real load cell's
    tens-of-thousands-count raw signal. So the calibration factor here
    (0.42 = 2100/5000) is specific to the SIMULATED chip. Don't reuse
    a real-hardware calibration value here, and don't reuse this 0.42
    value on real hardware — they solve different problems.
  - 1 pushbutton is the explicit trigger: set weight + color first,
    then press the button to grade. This was a deliberate choice over
    auto-triggering on weight crossing a threshold — the button gives
    a clean, single, deliberate signal instead of an accidental partial
    drag mid-slider-movement possibly registering as an early trigger.
  - No IR beam anywhere in this design (removed on both the real
    firmware and every version of this simulation).
  - Sorting sequence: the diverter gate (servo 2 or 3) moves FIRST,
    since the grade is already known — then the swipe servo pushes the
    fruit into the now-correctly-positioned gate.
  - No live jam detection in this build — the buzzer instead gives a
    short confirmation beep when a sort cycle completes.
  - Wokwi's RP2040 simulator only simulates ONE core, so this sketch
    does not use setup1()/loop1() — everything runs single-threaded in
    loop() with millis()-based timers.

  ==== v5 CHANGE: BLE + app-side grading ====
  v4 graded entirely on-device (computeGrade(), driven straight into
  the servos/LEDs from a button press). The iPad app's whole pipeline
  (SyncEngine + Sync/FruitGrader.swift) expects to be the one deciding
  the grade — the ESP32 firmware at ../ble.ino only ever reports raw
  sensor data and waits for a grade command back. This sketch now does
  the same: on button press it sends a 12-byte sensor packet over BLE
  (same GATT service/characteristics, same byte layout as ../ble.ino —
  see notifySensorData below) and waits for the app's 1-byte grade
  command before sorting.

  This board's onboard NINA-W102 module is programmed via the
  ArduinoBLE library, not ESP32's BLEDevice.h (../ble.ino targets a
  real ESP32 DevKit, a different chip family) — the GATT contract is
  identical, only the library API differs.

  Sensor model mismatch: this sketch has no real RGB sensor, only a
  maturity % potentiometer. Since the wire packet (and FruitGrader)
  expects raw R/G/B + a colorCode, maturity is translated into one of
  three bands reusing ../ble.ino's own calibrated reference values
  (ORANGE/YELLOW/GREEN) — see mapMaturityToColor(). This means the
  app's grade for a given fruit here is driven mostly by weight (per
  FruitGrader's own bands) once maturity clears the ORANGE/YELLOW
  threshold, not by the finer maturity gradient this sketch's own
  MATURITY_GRADE_A_MIN (70%) implies — an inherent limit of mapping a
  percentage onto a 3-color reference table, not a bug. computeGrade()
  is kept only as an offline fallback (see STATE_AWAITING_GRADE) for
  when no app is connected or it doesn't respond in time — not the
  live source of truth for sorting when BLE is up.

  Not verified whether Wokwi's browser simulator actually virtualizes
  BLE end-to-end for this specific board the way it does scanning/
  advertising for some ESP32 projects — this code is correct against
  ArduinoBLE and the app's GATT contract either way, but confirm BLE
  actually connects in your Wokwi project before relying on it for a
  demo; a real Nano RP2040 Connect board will work regardless.
*/

#include <ArduinoBLE.h>
#include <HX711.h>
#include <LiquidCrystal.h>
#include <Servo.h>

// ================= Pins =================
const int HX711_DOUT_PIN    = 2;
const int HX711_SCK_PIN     = 3;
const int LED_GREEN_PIN     = 4;   // Grade A
const int LED_YELLOW_PIN    = 5;   // Grade B
const int LED_RED_PIN       = 6;   // Grade C, D, or E (rejected)
const int BUZZER_PIN        = 7;
const int LCD_RS_PIN        = 8;
const int LCD_EN_PIN        = 9;
const int LCD_D4_PIN        = 10;
const int LCD_D5_PIN        = 11;
const int LCD_D6_PIN        = 12;
const int LCD_D7_PIN        = 13;
const int COLOR_SIM_PIN     = A0;  // potentiometer stands in for the TCS34725
const int SWIPE_SERVO_PIN   = A1;
const int DIVERT_AB_PIN     = A2;  // routes Grade A/B fruit to the "next pipe"
const int DIVERT_CD_PIN     = A3;  // routes Grade C/D/E fruit to "rejected"
const int TRIGGER_BUTTON_PIN = A4; // press = "a fruit has arrived, grade it"

// ============= BLE (matches ../ble.ino's GATT contract exactly) =============
const char* BLE_SERVICE_UUID   = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
const char* BLE_SENSOR_UUID    = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
const char* BLE_COMMAND_UUID   = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";

BLEService sensorService(BLE_SERVICE_UUID);
BLECharacteristic sensorCharacteristic(BLE_SENSOR_UUID, BLERead | BLENotify, 12);
BLECharacteristic commandCharacteristic(BLE_COMMAND_UUID, BLEWrite, 1);

bool bleWasConnected = false;

// ============= Calibration / thresholds =============
// 0.42 = 2100 raw counts / 5000g, matching Wokwi's simulated "5kg" HX711
// (see header note) — NOT a real-hardware calibration value.
const float HX711_CALIBRATION_FACTOR = 0.42f;
const float MIN_VALID_WEIGHT_G       = 40.0f;   // below this, treat as "nothing set" and skip grading

const float MATURITY_GRADE_A_MIN = 70.0f;   // % — only used by the offline fallback grade now
const float MATURITY_GRADE_B_MIN = 50.0f;   // %
const float MATURITY_GRADE_C_MIN = 30.0f;   // % — below this falls to Grade D, and to the GREEN color band
const float WEIGHT_GRADE_A_MIN_G = 150.0f;
const float WEIGHT_GRADE_B_MIN_G = 100.0f;

const uint16_t MEASURING_DELAY_MS   = 600;   // brief "Weighing..." pause for demo feel
const uint16_t AWAIT_GRADE_TIMEOUT_MS = 3000; // how long to wait for the app's grade command before falling back
const uint16_t SWIPE_HOLD_MS        = 400;   // how long the swipe servo holds its push
const uint16_t DIVERT_SETTLE_MS     = 300;   // let the gate finish moving before swiping
const uint16_t POST_SWIPE_CLEAR_MS  = 500;   // fixed "fruit rolling away" delay before reset
const int      NEUTRAL_ANGLE        = 90;
const int      SWIPE_ANGLE          = 170;
const int      DIVERT_A_ANGLE       = 45;
const int      DIVERT_B_ANGLE       = 135;
const int      DIVERT_C_ANGLE       = 45;
const int      DIVERT_D_ANGLE       = 135;
const uint16_t CONFIRM_BEEP_MS      = 150;   // cycle-complete chirp
const uint16_t CONFIRM_BEEP_HZ      = 4000;

HX711 scale;
LiquidCrystal lcd(LCD_RS_PIN, LCD_EN_PIN, LCD_D4_PIN, LCD_D5_PIN, LCD_D6_PIN, LCD_D7_PIN);
Servo swipeServo, divertAB, divertCD;

enum SystemState { STATE_IDLE, STATE_MEASURING, STATE_AWAITING_GRADE, STATE_SORTING, STATE_RESET };
SystemState state = STATE_IDLE;

// Last graded fruit + running batch tally
float lastWeight = 0, lastMaturity = 0;
char  lastGrade = '-';
char  fallbackGrade = '-';   // computeGrade() result, used only if the app doesn't answer in time
uint32_t fruitCount = 0, gradeACount = 0, gradeBCount = 0, gradeCCount = 0, gradeDCount = 0;

// Sorting sub-steps: 0 position gate, 1 settle then swipe, 2 hold swipe, 3 clear delay
uint8_t  sortingStep = 0;
uint32_t sortingStepStartMs = 0;
uint32_t measuringStartMs   = 0;
uint32_t awaitingGradeStartMs = 0;
uint32_t lcdRefreshMs       = 0;

// LCD change-detection cache, avoids redundant writes
char lcdLine1[17] = "", lcdLine2[17] = "";

void writeLcd(uint8_t row, const char* text) {
  char padded[17];
  size_t len = strlen(text);
  size_t n = (len < 16) ? len : 16;
  memcpy(padded, text, n);
  for (size_t i = n; i < 16; i++) padded[i] = ' ';
  padded[16] = '\0';

  char* cache = (row == 0) ? lcdLine1 : lcdLine2;
  if (strcmp(padded, cache) == 0) return;
  strcpy(cache, padded);

  lcd.setCursor(0, row);
  lcd.print(padded);
}

void setGradeLED(char grade) {
  digitalWrite(LED_GREEN_PIN,  grade == 'A' ? HIGH : LOW);
  digitalWrite(LED_YELLOW_PIN, grade == 'B' ? HIGH : LOW);
  digitalWrite(LED_RED_PIN,   (grade == 'C' || grade == 'D' || grade == 'E') ? HIGH : LOW);
}

void clearGradeLEDs() {
  digitalWrite(LED_GREEN_PIN, LOW);
  digitalWrite(LED_YELLOW_PIN, LOW);
  digitalWrite(LED_RED_PIN, LOW);
}

// Offline fallback only — see the v5 header note. Not used when the app
// answers the BLE grade request in time.
char computeGrade(float weight_g, float maturity_pct) {
  if (maturity_pct >= MATURITY_GRADE_A_MIN && weight_g >= WEIGHT_GRADE_A_MIN_G) return 'A';
  if (maturity_pct >= MATURITY_GRADE_B_MIN && weight_g >= WEIGHT_GRADE_B_MIN_G) return 'B';
  if (maturity_pct >= MATURITY_GRADE_C_MIN) return 'C';
  return 'D';
}

// The app's grade command byte (1-5, see ../ble.ino's CMD_GRADE_*) back
// into this sketch's grade letters. 4 ("Edible") and 5 ("Reject") both
// fall through to this design's C/D divert gate — there's no dedicated
// third physical lane for reject, just the two gates already wired.
char gradeFromCommandByte(uint8_t command) {
  switch (command) {
    case 1: return 'A';
    case 2: return 'B';
    case 3: return 'C';
    case 4: return 'D';
    case 5: return 'E';
    default: return '-';
  }
}

// Maturity % -> raw R/G/B + colorCode, reusing ../ble.ino's own
// calibrated ColorReference values (not invented here) so a connected
// app's FruitGrader sees the same reference points real hardware would
// send. Banded at this sketch's own MATURITY_GRADE_C_MIN/B_MIN
// thresholds — see the v5 header note on why finer maturity gradients
// beyond that don't otherwise affect the app's grade.
void mapMaturityToColor(float maturityPct, uint16_t &r, uint16_t &g, uint16_t &b, uint8_t &colorCode) {
  if (maturityPct < MATURITY_GRADE_C_MIN) {
    r = 211; g = 154; b = 183; colorCode = 4;  // GREEN — unripe
  } else if (maturityPct < MATURITY_GRADE_B_MIN) {
    r = 74; g = 104; b = 145; colorCode = 3;   // YELLOW — turning
  } else {
    r = 83; g = 178; b = 181; colorCode = 2;   // ORANGE — ripe
  }
}

// Same 12-byte little-endian layout as ../ble.ino's notifySensorData —
// see Networking/DTOs.swift on the app side for the decoder this must
// stay in sync with.
void notifySensorData(float weightG, uint16_t rawR, uint16_t rawG, uint16_t rawB, uint8_t colorCode, bool hxReady, bool colorReady) {
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

  packet[10] = colorCode;

  packet[11] = 0;
  if (hxReady) packet[11] |= 0x01;
  if (colorReady) packet[11] |= 0x02;

  sensorCharacteristic.writeValue(packet, 12);
}

// One-shot press detection — returns true only on the press edge, not
// while held. Wokwi's default bounce simulation is disabled for this
// button in diagram.json, so no extra debouncing is needed here.
bool buttonPressedEdge() {
  static bool lastState = HIGH;   // HIGH = not pressed (INPUT_PULLUP idle state)
  bool nowState = digitalRead(TRIGGER_BUTTON_PIN);
  bool edge = (nowState == LOW && lastState == HIGH);
  lastState = nowState;
  return edge;
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(10);   // be explicit: 0-1023, matches classic Arduino analogRead()

  pinMode(LED_GREEN_PIN, OUTPUT);
  pinMode(LED_YELLOW_PIN, OUTPUT);
  pinMode(LED_RED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(TRIGGER_BUTTON_PIN, INPUT_PULLUP);
  clearGradeLEDs();
  noTone(BUZZER_PIN);

  lcd.begin(16, 2);
  writeLcd(0, "HaloBiki Ready");
  writeLcd(1, "Press button...");

  // Tare while the slider is at its resting position (0kg) so
  // readings below reflect the actual dragged weight.
  scale.begin(HX711_DOUT_PIN, HX711_SCK_PIN);
  scale.set_scale(HX711_CALIBRATION_FACTOR);
  scale.tare();

  swipeServo.attach(SWIPE_SERVO_PIN);
  divertAB.attach(DIVERT_AB_PIN);
  divertCD.attach(DIVERT_CD_PIN);
  swipeServo.write(NEUTRAL_ANGLE);
  divertAB.write(NEUTRAL_ANGLE);
  divertCD.write(NEUTRAL_ANGLE);

  if (!BLE.begin()) {
    Serial.println("Gagal memulai BLE!");
  } else {
    BLE.setLocalName("HaloBiki-Sim");
    BLE.setAdvertisedService(sensorService);
    sensorService.addCharacteristic(sensorCharacteristic);
    sensorService.addCharacteristic(commandCharacteristic);
    BLE.addService(sensorService);
    BLE.advertise();
    Serial.println("BLE aktif, menunggu koneksi...");
  }
}

void loop() {
  BLE.poll();   // must run every iteration regardless of state to keep the BLE stack responsive

  bool nowConnected = BLE.central() && BLE.central().connected();
  if (nowConnected != bleWasConnected) {
    Serial.println(nowConnected ? "App terhubung lewat BLE." : "App terputus.");
    bleWasConnected = nowConnected;
  }

  bool pressed = buttonPressedEdge();   // computed every iteration so state never goes stale

  switch (state) {
    case STATE_IDLE:           handleIdle(pressed); break;
    case STATE_MEASURING:      handleMeasuring(); break;
    case STATE_AWAITING_GRADE: handleAwaitingGrade(); break;
    case STATE_SORTING:        handleSorting(); break;
    case STATE_RESET:          handleReset(); break;
  }
}

void handleIdle(bool pressed) {
  if (millis() - lcdRefreshMs >= 200) {
    lcdRefreshMs = millis();
    char buf[17];
    snprintf(buf, sizeof(buf), "A%lu B%lu C%lu D%lu",
             (unsigned long)gradeACount, (unsigned long)gradeBCount,
             (unsigned long)gradeCCount, (unsigned long)gradeDCount);
    writeLcd(0, "Ready");
    writeLcd(1, buf);
  }

  if (pressed) {
    measuringStartMs = millis();
    writeLcd(0, "Weighing...");
    writeLcd(1, "");
    state = STATE_MEASURING;
  }
}

void handleMeasuring() {
  if (millis() - measuringStartMs < MEASURING_DELAY_MS) return;

  float w = scale.get_units(5);   // average a few samples for a steadier reading
  if (w < MIN_VALID_WEIGHT_G) {
    // Slider still near 0 — nothing was actually set. Don't grade a
    // phantom fruit; bounce back to Ready instead.
    writeLcd(0, "Set weight first");
    writeLcd(1, "then press button");
    delay(1000);   // one-off blocking pause is fine here — it's a rare, unimportant path
    state = STATE_IDLE;
    return;
  }

  // ---- Lock in the measurement ----
  int potVal = analogRead(COLOR_SIM_PIN);
  float maturity = (float)map(potVal, 0, 1023, 0, 100);

  lastWeight = w;
  lastMaturity = maturity;
  fallbackGrade = computeGrade(lastWeight, maturity);

  uint16_t rawR, rawG, rawB;
  uint8_t colorCode;
  mapMaturityToColor(maturity, rawR, rawG, rawB, colorCode);

  bool centralConnected = BLE.central() && BLE.central().connected();
  if (centralConnected) {
    notifySensorData(lastWeight, rawR, rawG, rawB, colorCode, true, true);
    writeLcd(0, "Menunggu grade..");
    char buf[17];
    snprintf(buf, sizeof(buf), "%dg", (int)lastWeight);
    writeLcd(1, buf);
    awaitingGradeStartMs = millis();
    state = STATE_AWAITING_GRADE;
  } else {
    // No app connected — go straight to the offline fallback rather
    // than waiting the full timeout for a command that can't arrive.
    finalizeGrade(fallbackGrade);
  }
}

void handleAwaitingGrade() {
  if (commandCharacteristic.written()) {
    const uint8_t* data = commandCharacteristic.value();
    if (commandCharacteristic.valueLength() > 0) {
      char grade = gradeFromCommandByte(data[0]);
      finalizeGrade(grade != '-' ? grade : fallbackGrade);
      return;
    }
  }

  if (millis() - awaitingGradeStartMs >= AWAIT_GRADE_TIMEOUT_MS) {
    Serial.println("Timeout menunggu grade dari app, pakai grade offline.");
    finalizeGrade(fallbackGrade);
  }
}

// Locks in the grade actually used for sorting — whichever source it
// came from — updates the batch tally, and moves into the sorting
// sequence. Both handleMeasuring (no app connected) and
// handleAwaitingGrade (command received, or timed out) funnel here so
// there's exactly one place that finalizes a fruit.
void finalizeGrade(char grade) {
  lastGrade = grade;
  fruitCount++;
  if      (lastGrade == 'A') gradeACount++;
  else if (lastGrade == 'B') gradeBCount++;
  else if (lastGrade == 'C') gradeCCount++;
  else                       gradeDCount++;   // D and E (reject) share the tally, same as the divert gate

  setGradeLED(lastGrade);

  Serial.print("Fruit #");        Serial.print(fruitCount);
  Serial.print(" | Weight: ");    Serial.print(lastWeight);
  Serial.print("g | Maturity: "); Serial.print(lastMaturity);
  Serial.print("% | Grade: ");    Serial.println(lastGrade);

  sortingStep = 0;
  sortingStepStartMs = millis();
  state = STATE_SORTING;
}

void handleSorting() {
  char buf[17];
  snprintf(buf, sizeof(buf), "Grade %c  %dg", lastGrade, (int)lastWeight);
  uint32_t elapsed = millis() - sortingStepStartMs;

  switch (sortingStep) {
    case 0:   // position the gate for this grade — BEFORE the swipe, not after
      writeLcd(0, "Positioning...");
      writeLcd(1, buf);
      if      (lastGrade == 'A') divertAB.write(DIVERT_A_ANGLE);
      else if (lastGrade == 'B') divertAB.write(DIVERT_B_ANGLE);
      else if (lastGrade == 'C') divertCD.write(DIVERT_C_ANGLE);
      else                       divertCD.write(DIVERT_D_ANGLE);   // D and E share this gate
      sortingStep = 1;
      sortingStepStartMs = millis();
      break;

    case 1:   // let the gate finish moving, then push the fruit into it
      if (elapsed >= DIVERT_SETTLE_MS) {
        writeLcd(0, "Sorting...");
        swipeServo.write(SWIPE_ANGLE);
        sortingStep = 2;
        sortingStepStartMs = millis();
      }
      break;

    case 2:   // hold the swipe, then return it to neutral + confirm beep
      if (elapsed >= SWIPE_HOLD_MS) {
        swipeServo.write(NEUTRAL_ANGLE);
        tone(BUZZER_PIN, CONFIRM_BEEP_HZ, CONFIRM_BEEP_MS);
        sortingStep = 3;
        sortingStepStartMs = millis();
      }
      break;

    case 3:   // fixed delay simulating the fruit rolling clear, then reset
      if (elapsed >= POST_SWIPE_CLEAR_MS) {
        state = STATE_RESET;
      }
      break;
  }
}

void handleReset() {
  divertAB.write(NEUTRAL_ANGLE);
  divertCD.write(NEUTRAL_ANGLE);
  clearGradeLEDs();
  state = STATE_IDLE;
}
