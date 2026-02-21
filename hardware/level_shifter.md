# 74HCT245 Level Shifter Wiring

## Why a Level Shifter?

The PYNQ-Z2 PMODA pins output 3.3V logic levels. WS2812B LEDs require:
- VIH (input high voltage) = 0.7 x VDD = 0.7 x 5V = 3.5V

Since 3.3V < 3.5V, the WS2812 won't reliably recognize high signals from
the FPGA. The 74HCT245 shifts 3.3V logic to 5V logic.

## Parts

- 1x 74HCT245 (DIP-20 for breadboard, or TSSOP-20 for PCB)
- 1x breadboard
- Jumper wires
- 5V power supply (shared with LED strips)
- 100nF bypass capacitor (place near 74HCT245 VCC pin)

## 74HCT245 Pinout (DIP-20)

```
        ┌────────┐
   DIR ─┤1     20├─ VCC (5V)
   A1  ─┤2     19├─ OE (active low)
   A2  ─┤3     18├─ B1
   A3  ─┤4     17├─ B2
   A4  ─┤5     16├─ B3
   A5  ─┤6     15├─ B4
   A6  ─┤7     14├─ B5
   A7  ─┤8     13├─ B6
   A8  ─┤9     12├─ B7
   GND ─┤10    11├─ B8
        └────────┘
```

## Wiring

| 74HCT245 Pin | Connection | Notes |
|---------------|------------|-------|
| Pin 1 (DIR) | 5V (VCC) | A→B direction (FPGA to LEDs) |
| Pin 2 (A1) | PMODA pin 1 (Y18) | WS2812 output 0 input |
| Pin 3 (A2) | PMODA pin 2 (Y19) | WS2812 output 1 input |
| Pin 4 (A3) | PMODA pin 3 (Y16) | WS2812 output 2 input |
| Pin 5 (A4) | PMODA pin 4 (Y17) | WS2812 output 3 input |
| Pin 6 (A5) | PMODA pin 7 (U18) | WS2812 output 4 input |
| Pin 7 (A6) | PMODA pin 8 (U19) | WS2812 output 5 input |
| Pin 8 (A7) | PMODA pin 9 (W18) | WS2812 output 6 input |
| Pin 9 (A8) | PMODA pin 10 (W19) | WS2812 output 7 input |
| Pin 10 (GND) | Ground | Shared with FPGA and LED supply |
| Pin 11 (B8) | LED strip 7 DIN | 5V level output |
| Pin 12 (B7) | LED strip 6 DIN | 5V level output |
| Pin 13 (B6) | LED strip 5 DIN | 5V level output |
| Pin 14 (B5) | LED strip 4 DIN | 5V level output |
| Pin 15 (B4) | LED strip 3 DIN | 5V level output |
| Pin 16 (B3) | LED strip 2 DIN | 5V level output |
| Pin 17 (B2) | LED strip 1 DIN | 5V level output |
| Pin 18 (B1) | LED strip 0 DIN | 5V level output |
| Pin 19 (OE) | Ground | Enable outputs (active low) |
| Pin 20 (VCC) | 5V | Power supply |

## Signal Path

```
FPGA pin (3.3V) ──► 74HCT245 A input ──► 74HCT245 B output (5V) ──► WS2812 DIN
```

## PMODA Connector Pinout (PYNQ-Z2)

```
  ┌─────────────────────────────┐
  │  PMODA (top row, J1)        │
  │                             │
  │  3.3V  GND  JA4  JA3  JA2  JA1  │
  │  3.3V  GND  JA10 JA9  JA8  JA7  │
  │                             │
  └─────────────────────────────┘
```

The PMODA connector provides 3.3V and GND pins which can power the 74HCT245
logic input side. The 5V supply must come from an external source (same supply
as the LED strips).

## Power Notes

- Each WS2812B pixel draws up to 60mA at full white (20mA per color)
- For 510 pixels per strip: 510 x 60mA = 30.6A max per strip at full white
- Typical Christmas display usage: ~30% brightness average = ~10A per strip
- Use appropriately rated 5V power supplies
- Add 1000uF electrolytic capacitor across 5V/GND near the LED strip power input
- Keep data wire runs short or add a 330-470 ohm series resistor at WS2812 DIN

## Ground Connection

All grounds must be connected together:
- PYNQ-Z2 GND (from PMODA)
- 74HCT245 GND (pin 10)
- 5V power supply GND
- WS2812 LED strip GND
