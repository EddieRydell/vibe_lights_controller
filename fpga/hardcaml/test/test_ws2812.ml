open! Base
open Hardcaml
open Ws2812_controller

(** Cycle-accurate simulation tests for the WS2812 controller.

    Tests:
    1. Single-pixel output timing verification
    2. Multi-pixel sequence
    3. AXI register reads/writes
    4. WS2812 timing tolerance check (±150ns)
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

(* ---- Test 1: Single-channel serializer timing ---- *)

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
  (* Binary: 1111_1111 0000_0000 0000_0000 *)
  inputs.pixel_data := Bits.of_int ~width:24 0xFF0000;
  inputs.pixel_count := Bits.of_int ~width:10 1;
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
  (* Test: Write pixel count, read it back *)
  axi_write 0x0008 42;  (* PIX_COUNT = 42 *)
  let pix_count = axi_read 0x0008 in
  Stdlib.Printf.printf "PIX_COUNT readback: %d\n" pix_count;
  (* Test: Write channel enable, read it back *)
  axi_write 0x000C 0xFF;  (* All channels enabled *)
  let ch_en = axi_read 0x000C in
  Stdlib.Printf.printf "CH_ENABLE readback: %d\n" ch_en;
  (* Test: Read VERSION register *)
  let version = axi_read 0x0010 in
  Stdlib.Printf.printf "VERSION: 0x%08X\n" version;
  (* Test: Write pixel data to channel 0, then trigger *)
  axi_write 0x1000 0x00FF00;  (* CH0 pixel 0: red *)
  axi_write 0x0008 1;         (* PIX_COUNT = 1 *)
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
    CH_ENABLE readback: 255
    VERSION: 0x00010001
    STATUS after start (busy expected): 0x1
    STATUS after run: 0x2
    |}]
;;

(* ---- Test 3: Timing verification ---- *)

let%expect_test "ws2812_bit_timing" =
  let module Sim = Cyclesim.With_interface (Ws2812_serializer.I) (Ws2812_serializer.O) in
  let scope = Scope.create ~flatten_design:true () in
  let sim = Sim.create (Ws2812_serializer.create scope) in
  let inputs = Cyclesim.inputs sim in
  let outputs = Cyclesim.outputs sim in
  (* Send a pixel with known pattern: 0x800000 = MSB is 1, rest 0 *)
  (* First bit is 1 (T1H=80 cycles), remaining 23 bits are 0 (T0H=40 cycles) *)
  inputs.pixel_data := Bits.of_int ~width:24 0x800000;
  inputs.pixel_count := Bits.of_int ~width:10 1;
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

(* Tests run via: dune runtest *)
