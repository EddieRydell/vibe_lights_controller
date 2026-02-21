## PYNQ-Z2 Pin Constraints for WS2812 Controller
## Target: Zynq XC7Z020CLG400-1
## Connector: PMODA (directly on PYNQ-Z2 board)
##
## 8x WS2812 data outputs mapped to PMODA pins.
## Active low/high doesn't apply — WS2812 is push-pull digital.
## LVCMOS33 matches the PYNQ-Z2 3.3V bank voltage for PMODA.

## Output 0 — PMODA pin 1 (JA1)
set_property PACKAGE_PIN Y18  [get_ports {ws2812_out[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[0]}]
set_property SLEW FAST [get_ports {ws2812_out[0]}]
set_property DRIVE 8 [get_ports {ws2812_out[0]}]

## Output 1 — PMODA pin 2 (JA2)
set_property PACKAGE_PIN Y19  [get_ports {ws2812_out[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[1]}]
set_property SLEW FAST [get_ports {ws2812_out[1]}]
set_property DRIVE 8 [get_ports {ws2812_out[1]}]

## Output 2 — PMODA pin 3 (JA3)
set_property PACKAGE_PIN Y16  [get_ports {ws2812_out[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[2]}]
set_property SLEW FAST [get_ports {ws2812_out[2]}]
set_property DRIVE 8 [get_ports {ws2812_out[2]}]

## Output 3 — PMODA pin 4 (JA4)
set_property PACKAGE_PIN Y17  [get_ports {ws2812_out[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[3]}]
set_property SLEW FAST [get_ports {ws2812_out[3]}]
set_property DRIVE 8 [get_ports {ws2812_out[3]}]

## Output 4 — PMODA pin 7 (JA7)
set_property PACKAGE_PIN U18  [get_ports {ws2812_out[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[4]}]
set_property SLEW FAST [get_ports {ws2812_out[4]}]
set_property DRIVE 8 [get_ports {ws2812_out[4]}]

## Output 5 — PMODA pin 8 (JA8)
set_property PACKAGE_PIN U19  [get_ports {ws2812_out[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[5]}]
set_property SLEW FAST [get_ports {ws2812_out[5]}]
set_property DRIVE 8 [get_ports {ws2812_out[5]}]

## Output 6 — PMODA pin 9 (JA9)
set_property PACKAGE_PIN W18  [get_ports {ws2812_out[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[6]}]
set_property SLEW FAST [get_ports {ws2812_out[6]}]
set_property DRIVE 8 [get_ports {ws2812_out[6]}]

## Output 7 — PMODA pin 10 (JA10)
set_property PACKAGE_PIN W19  [get_ports {ws2812_out[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ws2812_out[7]}]
set_property SLEW FAST [get_ports {ws2812_out[7]}]
set_property DRIVE 8 [get_ports {ws2812_out[7]}]
