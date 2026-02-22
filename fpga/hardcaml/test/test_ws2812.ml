open! Base
open Hardcaml
open Ws2812_controller

(** Cycle-accurate simulation tests for the WS2812 controller.

    Tests:
    1. Single-pixel output timing verification (RGB mode)
    2. Top-level AXI register write/read (including v2.0.0 registers)
    3. WS2812 timing tolerance check (±150ns)
    4. Per-channel pixel count registers
    5. RGBW mode timing verification
*)

(* ---- Helpers ---- *)

let clock_period_ns = 10  (* 100 MHz *)
let t0h_cycles = 40
let t1h_cycles = 80
let bit_period_cycles = 125
let reset_cycles = 5000
let timing_tolerance_cycles = 15  (* ±150ns at 100 MHz = ±15 cycles *)

(** Step the simulation for [n] cycles *)
let step sim n =
  for _ = 1 to n do
    Cyclesim.cycle sim
  done
;;

(* ---- Test 1: Single-channel serializer timing (RGB mode) ---- *)

let%expect_test "single_pixel_timing" =
  let module Sim = Cyclesim.With_interface (Ws2812_serializer.I) (Ws2812_serializer.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim =
    Sim.create
      (Ws2812_serializer.create scope)
  in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Set up a single pixel: GRB = 0xFF0000 (full green, no red, no blue) *)
  (* In RGB mode, 24-bit data is left-aligned into 32-bit shift reg *)
  inputs.pixel_data := Bits.of_int ~width:32 0xFF0000;
  inputs.pixel_count := Bits.of_int ~width:10 1;
  inputs.rgbw_mode := Bits.gnd;
  inputs.start := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  (* Let it run through one pixel (24 bits * 125 cycles + reset) *)
  let total_cycles = (24 * bit_period_cycles) + reset_cycles + 100 in
  step sim total_cycles;
  (* Check that we eventually get done *)
  let done_val = Bits.to_int !(outputs.done_) in
  Stdlib.Printf.printf "Done after transmission: %d\n" done_val;
  [%expect {| Done after transmission: 1 |}]
;;

(* ---- Test 2: Top-level AXI register write/read ---- *)

let%expect_test "axi_register_rw" =
  let module Sim = Cyclesim.With_interface (Top.I) (Top.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Top.create scope) in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Helper: AXI-Lite write *)
  let axi_write addr data =
    (* Address phase *)
    inputs.s_axi_awaddr := Bits.of_int ~width:16 addr;
    inputs.s_axi_awvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_awvalid := Bits.gnd;
    (* Data phase *)
    inputs.s_axi_wdata := Bits.of_int ~width:32 data;
    inputs.s_axi_wstrb := Bits.of_int ~width:4 0xF;
    inputs.s_axi_wvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_wvalid := Bits.gnd;
    (* Response phase *)
    inputs.s_axi_bready := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_bready := Bits.gnd;
    Cyclesim.cycle sim
  in
  (* Helper: AXI-Lite read *)
  let axi_read addr =
    inputs.s_axi_araddr := Bits.of_int ~width:16 addr;
    inputs.s_axi_arvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_arvalid := Bits.gnd;
    inputs.s_axi_rready := Bits.vdd;
    Cyclesim.cycle sim;
    let data = Bits.to_int !(outputs.s_axi_rdata) in
    inputs.s_axi_rready := Bits.gnd;
    Cyclesim.cycle sim;
    data
  in
  (* Test: Write CH0 pixel count via backward compat register, read it back *)
  axi_write 0x0008 42;  (* PIX_COUNT = 42, should set CH0 *)
  let pix_count = axi_read 0x0008 in
  Stdlib.Printf.printf "PIX_COUNT readback: %d\n" pix_count;
  (* Test: Read CH0_PIX_COUNT — should also be 42 *)
  let ch0_pix = axi_read 0x0014 in
  Stdlib.Printf.printf "CH0_PIX_COUNT readback: %d\n" ch0_pix;
  (* Test: Write per-channel pixel counts *)
  axi_write 0x0018 100;  (* CH1_PIX_COUNT = 100 *)
  let ch1_pix = axi_read 0x0018 in
  Stdlib.Printf.printf "CH1_PIX_COUNT readback: %d\n" ch1_pix;
  axi_write 0x0030 512;  (* CH7_PIX_COUNT = 512 *)
  let ch7_pix = axi_read 0x0030 in
  Stdlib.Printf.printf "CH7_PIX_COUNT readback: %d\n" ch7_pix;
  (* Test: Write PIX_FMT, read it back *)
  axi_write 0x0034 0x22;  (* Channels 1 and 5 in RGBW mode *)
  let pix_fmt = axi_read 0x0034 in
  Stdlib.Printf.printf "PIX_FMT readback: 0x%02X\n" pix_fmt;
  (* Test: Write channel enable, read it back *)
  axi_write 0x000C 0xFF;  (* All channels enabled *)
  let ch_en = axi_read 0x000C in
  Stdlib.Printf.printf "CH_ENABLE readback: %d\n" ch_en;
  (* Test: Read VERSION register *)
  let version = axi_read 0x0010 in
  Stdlib.Printf.printf "VERSION: 0x%08X\n" version;
  (* Test: Write pixel data to channel 0, then trigger *)
  axi_write 0x1000 0x00FF00;  (* CH0 pixel 0: red *)
  axi_write 0x0014 1;         (* CH0_PIX_COUNT = 1 *)
  axi_write 0x000C 0x01;      (* Enable CH0 only *)
  axi_write 0x0000 0x01;      (* Start *)
  (* Check busy *)
  let status = axi_read 0x0004 in
  Stdlib.Printf.printf "STATUS after start (busy expected): 0x%X\n" status;
  (* Let it run *)
  step sim 10000;
  let status2 = axi_read 0x0004 in
  Stdlib.Printf.printf "STATUS after run: 0x%X\n" status2;
  [%expect
    {|
    PIX_COUNT readback: 42
    CH0_PIX_COUNT readback: 42
    CH1_PIX_COUNT readback: 100
    CH7_PIX_COUNT readback: 512
    PIX_FMT readback: 0x22
    CH_ENABLE readback: 255
    VERSION: 0x00020000
    STATUS after start (busy expected): 0x1
    STATUS after run: 0x2
    |}]
;;

(* ---- Test 3: Timing verification (RGB mode) ---- *)

let%expect_test "ws2812_bit_timing" =
  let module Sim = Cyclesim.With_interface (Ws2812_serializer.I) (Ws2812_serializer.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Ws2812_serializer.create scope) in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Send a pixel with known pattern: 0x800000 = MSB is 1, rest 0 *)
  (* First bit is 1 (T1H=80 cycles), remaining 23 bits are 0 (T0H=40 cycles) *)
  inputs.pixel_data := Bits.of_int ~width:32 0x800000;
  inputs.pixel_count := Bits.of_int ~width:10 1;
  inputs.rgbw_mode := Bits.gnd;
  inputs.start := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  (* Skip load_pixel state *)
  Cyclesim.cycle sim;
  (* Measure first bit high time (should be T1H = 80 cycles for bit=1) *)
  let high_count = ref 0 in
  let measuring = ref true in
  while !measuring do
    Cyclesim.cycle sim;
    if Bits.to_int !(outputs.ws2812_out) = 1 then Int.incr high_count
    else measuring := false
  done;
  let t1h_ok =
    Int.abs (!high_count - t1h_cycles) <= timing_tolerance_cycles
  in
  Stdlib.Printf.printf
    "T1H measured: %d cycles (expected ~%d, tolerance ±%d): %s\n"
    !high_count
    t1h_cycles
    timing_tolerance_cycles
    (if t1h_ok then "PASS" else "FAIL");
  [%expect
    {| T1H measured: 80 cycles (expected ~80, tolerance ±15): PASS |}]
;;

(* ---- Test 4: RGBW mode single-pixel timing ---- *)

let%expect_test "rgbw_single_pixel_timing" =
  let module Sim = Cyclesim.With_interface (Ws2812_serializer.I) (Ws2812_serializer.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim =
    Sim.create
      (Ws2812_serializer.create scope)
  in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Set up a single RGBW pixel: 0xAABBCCDD *)
  inputs.pixel_data := Bits.of_int ~width:32 0xAABBCCDD;
  inputs.pixel_count := Bits.of_int ~width:10 1;
  inputs.rgbw_mode := Bits.vdd;  (* RGBW mode *)
  inputs.start := Bits.vdd;
  Cyclesim.cycle sim;
  inputs.start := Bits.gnd;
  (* Let it run through one RGBW pixel (32 bits * 125 cycles + reset) *)
  let total_cycles = (32 * bit_period_cycles) + reset_cycles + 100 in
  step sim total_cycles;
  (* Check that we eventually get done *)
  let done_val = Bits.to_int !(outputs.done_) in
  Stdlib.Printf.printf "RGBW done after transmission: %d\n" done_val;
  [%expect {| RGBW done after transmission: 1 |}]
;;

(* ---- Test 5: Per-channel pixel count via top-level AXI ---- *)

let%expect_test "per_channel_pixel_count" =
  let module Sim = Cyclesim.With_interface (Top.I) (Top.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Top.create scope) in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  let axi_write addr data =
    inputs.s_axi_awaddr := Bits.of_int ~width:16 addr;
    inputs.s_axi_awvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_awvalid := Bits.gnd;
    inputs.s_axi_wdata := Bits.of_int ~width:32 data;
    inputs.s_axi_wstrb := Bits.of_int ~width:4 0xF;
    inputs.s_axi_wvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_wvalid := Bits.gnd;
    inputs.s_axi_bready := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_bready := Bits.gnd;
    Cyclesim.cycle sim
  in
  let axi_read addr =
    inputs.s_axi_araddr := Bits.of_int ~width:16 addr;
    inputs.s_axi_arvalid := Bits.vdd;
    Cyclesim.cycle sim;
    inputs.s_axi_arvalid := Bits.gnd;
    inputs.s_axi_rready := Bits.vdd;
    Cyclesim.cycle sim;
    let data = Bits.to_int !(outputs.s_axi_rdata) in
    inputs.s_axi_rready := Bits.gnd;
    Cyclesim.cycle sim;
    data
  in
  (* Write different pixel counts to all 8 channels *)
  let counts = [| 10; 20; 30; 40; 50; 60; 70; 80 |] in
  for ch = 0 to 7 do
    axi_write (0x0014 + ch * 4) counts.(ch)
  done;
  (* Read them all back *)
  for ch = 0 to 7 do
    let val_ = axi_read (0x0014 + ch * 4) in
    let ok = val_ = counts.(ch) in
    Stdlib.Printf.printf "CH%d_PIX_COUNT: %d (expected %d) %s\n"
      ch val_ counts.(ch) (if ok then "PASS" else "FAIL")
  done;
  [%expect
    {|
    CH0_PIX_COUNT: 10 (expected 10) PASS
    CH1_PIX_COUNT: 20 (expected 20) PASS
    CH2_PIX_COUNT: 30 (expected 30) PASS
    CH3_PIX_COUNT: 40 (expected 40) PASS
    CH4_PIX_COUNT: 50 (expected 50) PASS
    CH5_PIX_COUNT: 60 (expected 60) PASS
    CH6_PIX_COUNT: 70 (expected 70) PASS
    CH7_PIX_COUNT: 80 (expected 80) PASS
    |}]
;;

(* Tests run via: dune runtest *)
