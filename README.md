# edgefield
Numberstation for norns
---

## CONCEPT

EdgeField transmits encoded text messages as spoken digit groups, mimicking cold war shortwave number stations. Plaintext is encoded using the CT-37c cipher — common letters map to single digits, less common letters to two-digit pairs. The screen decodes in real time, just barely trailing the audio.

---

## QUICK START

1. Connect USB keyboard and optionally a grid
2. Type your message (letters and spaces only)
3. Press **K3** or **ENTER** to transmit
4. Watch the screen decode as the station broadcasts
5. Message ends with operator ID spoken three times
6. Press **K2** at any time to kill the transmission

---

## HARDWARE CONTROLS

### Keys

| Key | Function |
|-----|----------|
| K2  | Kill transmission immediately — last sound trails off with echo decay |
| K3  | Begin transmission (also loads message file if input is empty) |

### Encoders

| Encoder | Function |
|---------|----------|
| E2 | Distance — meta-control for atmospheric depth (also: grid row 8) |
| E3 | FX Probability — chance of per-digit effect when idle |

### USB Keyboard

| Key | Function |
|-----|----------|
| Letters / Space | Type message into input buffer |
| BACKSPACE | Delete last character |
| ENTER | Transmit |

---

## TRANSMISSION STRUCTURE

Every transmission follows this sequence:

```
OPERATOR ID × 3   (attention signal, spoken dry)
MESSAGE BODY      (CT-37c encoded, broken into digit groups)
OPERATOR ID × 3   (sign-off, spoken dry)
```

Group size and timing are set in params. The body is zero-padded to fill the final group if needed.

---

## SCREEN

**Idle:** shows `EDGEFIELD [voice set]` with a blinking cursor and your typed message. FX probability and distance are shown at the bottom.

**Encoding:** brief flash of `ENCODING` as the text is converted.

**Transmitting:** shows `TX [voice set]` with a spinner. Three scrolling lines display the decoded message in real time — digits appear first, then collapse into letters as each code resolves.

**Signing off:** shows `SIGNING OFF` as operator ID repeats play out.

A dim distance bar runs along the bottom of the screen at all times.

---

## GRID (optional)

The grid is a live control surface. All controls take effect immediately.

```
ROW 1  cols 1-9   │ Drift slider
ROW 2  cols 1-9   │ Crush slider  
ROW 3  cols 1-9   │ FX Probability slider
       cols 10-12 │ } Live digit pair —
       col  13    │ }   first digit resolving
       cols 14-16 │ }   dim, CT-37c raw codes
ROW 4  cols 1-9   │ Carrier LFO speed  (bouncing pixel)
ROW 5  cols 1-9   │ Static LFO speed   (bouncing pixel)
ROW 6  cols 1-16  │ Carrier frequency depth (wave + bright pixel)
ROW 7  cols 1-16  │ Static level depth      (wave + bright pixel)
ROW 8  cols 1-16  │ Distance slider
```

**Sliders (rows 1-3, 8):** tap any button to set value. Gray fill shows current level left of the set point.

**LFO speed (rows 4-5):** tap to set rate. A single pixel bounces left and right, its speed matching the actual LFO rate.

**LFO depth (rows 6-7):** animated wave shows the LFO waveform. Bright pixel sets modulation depth — left is none, right is maximum. Carrier modulates ±400Hz around the set frequency. Static modulates ±50% around the set level.

**Live digits (rows 1-5, cols 10-16):** the raw incoming CT-37c pair appears dim in the corner as each digit is spoken, then clears shortly after resolving.

---

## PARAMS

### STATION

| Param | Range | Description |
|-------|-------|-------------|
| Operator ID | text | 3-digit station identifier, spoken at start and end |
| Voice Set | folders | Audio sample set to use from `audio/edgefield/voices/` |
| Message File | file | `.txt` file to load if input buffer is empty at transmit |
| Digits/Group | 3–5 | How many digits per spoken group |
| Digit Delay | 0.2–2.0s | Gap between individual digits |
| Group Delay | 0.5–5.0s | Pause between groups |

### SIGNAL

| Param | Range | Description |
|-------|-------|-------------|
| Bandwidth | 400–6000Hz | Master bandpass width — narrow for distant/degraded radio feel |
| Carrier Freq | 1000–9000Hz | Center frequency of the shortwave carrier tone |
| Static Level | 0.0–1.0 | Background noise floor level |

### VOICE FX

| Param | Range | Description |
|-------|-------|-------------|
| Drift | 0.0–0.5 | Random pitch warble on voice playback — tape aging effect |
| Crush | 0.0–0.08 | Master bitcrush depth — mild grit to lo-fi degradation |
| FX Probability | 0–100% | Chance each digit gets a random effect applied |

Random effects include: slapback echo, feedback echo, reverb, and soft-clip distortion. Each fires independently per digit — some will be dry, some processed, creating uneven transmission character.

### DISTANCE

| Param | Range | Description |
|-------|-------|-------------|
| Distance | 0.0–1.0 | Meta-control — simultaneously raises noise floor, narrows bandwidth, increases carrier level, and boosts atmospheric mix. Turn up for a signal received from very far away. |

---

## VOICE SETS

Place sample folders at `audio/edgefield/voices/[name]/`. Each folder needs `.wav` files named `0.wav` through `9.wav`. EdgeField scans for available sets on boot and lists them in params.

The included `H` set is the default. A `morse` set using tone samples for each digit works for a different aesthetic — technically approximate but effective.

---

## CT-37c ENCODING

Common letters encode as single digits for speed. The rest use two-digit pairs:

```
1=I  2=A  3=T  4=O  5=N  6=E

70=B  71=C  72=D  73=F  74=G  75=H
76=J  77=K  78=L  79=M  80=P  81=Q
82=R  83=S  84=U  85=V  86=W  87=X
88=Y  89=Z

99=SPACE
```

Only letters and spaces transmit. Numbers and punctuation in the input are silently dropped.

---

## FILE MESSAGES

Place `.txt` files in `data/edgefield/messages/`. Set the path in params under Message File. If the input buffer is empty when you press K3, the script loads and transmits the file contents. Useful for long pre-written messages.

The default file `coos.txt` loads automatically if present.

---

## AUDIO PATH

```
Voice samples → voiceBus
               ↓
         Per-digit FX (slapback / echo / reverb / distort)
               ↓
         Master bandpass + bitcrush + phaser
               ↓
         Persistent echo (normally dry, cranked on K2 kill)
               ↓
         Mix with ambient (carrier + static)
               ↓
         Limiter → output
```

Carrier frequency and static level are modulated by Lua-side LFOs, smoothed in SuperCollider with `.lag()` to prevent stepping.
