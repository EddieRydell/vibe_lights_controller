open! Base
open Hardcaml
open Signal

(** WS2812 single-channel serializer.

    Timing constants at 100 MHz clock:
    - T0H (0-bit high): 400ns = 40 cycles
    - T0L (0-bit low):  850ns = 85 cycles
    - T1H (1-bit high): 800ns = 80 cycles
    - T1L (1-bit low):  450ns = 45 cycles
    - Bit period:       1.25us = 125 cycles
    - Reset pulse:      >=50us = >=5000 cycles

    State machine: IDLE -> RESET_PULSE -> SEND_BIT (24 bits/pixel, MSB first, GRB) -> DONE
*)

(* Timing constants for 100 MHz clock *)
let t0h_cycles = 40
let t1h_cycles = 80
let bit_period_cycles = 125
let reset_cycles = 5000
let bits_per_pixel = 24
let max_pixels = 680

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; start : 'a  (** Pulse high to begin transmission *)
    ; pixel_count : 'a [@bits 10]  (** Number of pixels to transmit (1-680) *)
    ; pixel_data : 'a [@bits 24]  (** GRB pixel data from buffer read port *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ws2812_out : 'a  (** WS2812 data output pin *)
    ; busy : 'a  (** High while transmitting *)
    ; done_ : 'a  (** High when transmission complete (sticky until next start) *)
    ; read_addr : 'a [@bits 10]  (** Pixel buffer read address *)
    ; read_enable : 'a  (** Pixel buffer read enable *)
    }
  [@@deriving hardcaml]
end

(* State encoding *)
module State = struct
  type t =
    | Idle
    | Load_pixel
    | Send_bit_high
    | Send_bit_low
    | Next_bit
    | Next_pixel
    | Reset_pulse
    | Done
  [@@deriving sexp_of, compare, enumerate]
end

let create (scope : Scope.t) (i : _ I.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  let sm = Always.State_machine.create (module State) spec ~enable:vdd in
  (* Counters *)
  let cycle_count = Always.Variable.reg spec ~enable:vdd ~width:13 in
  let bit_index = Always.Variable.reg spec ~enable:vdd ~width:5 in
  let pixel_index = Always.Variable.reg spec ~enable:vdd ~width:10 in
  let pixel_shift_reg = Always.Variable.reg spec ~enable:vdd ~width:24 in
  let ws2812_out = Always.Variable.reg spec ~enable:vdd ~width:1 in
  let read_addr = Always.Variable.reg spec ~enable:vdd ~width:10 in
  let read_enable = Always.Variable.reg spec ~enable:vdd ~width:1 in
  let done_flag = Always.Variable.reg spec ~enable:vdd ~width:1 in
  (* Compute high-time based on current bit value *)
  let current_bit = bit pixel_shift_reg.value 23 in
  let high_time =
    mux2 current_bit
      (of_int ~width:13 t1h_cycles)
      (of_int ~width:13 t0h_cycles)
  in
  let low_time =
    mux2 current_bit
      (of_int ~width:13 (bit_period_cycles - t1h_cycles))
      (of_int ~width:13 (bit_period_cycles - t0h_cycles))
  in
  Always.(
    compile
      [ sm.switch
          [ ( State.Idle
            , [ ws2812_out <--. 0
              ; done_flag <-- done_flag.value
              ; read_enable <--. 0
              ; when_
                  i.start
                  [ pixel_index <--. 0
                  ; done_flag <--. 0
                  ; read_addr <--. 0
                  ; read_enable <--. 1
                  ; sm.set_next Load_pixel
                  ]
              ] )
          ; ( State.Load_pixel
            , [ read_enable <--. 0
              ; (* Data available this cycle from the read we issued *)
                pixel_shift_reg <-- i.pixel_data
              ; bit_index <--. 0
              ; sm.set_next Send_bit_high
              ] )
          ; ( State.Send_bit_high
            , [ ws2812_out <--. 1
              ; cycle_count <-- cycle_count.value +:. 1
              ; when_
                  (cycle_count.value >=: high_time -:. 1)
                  [ cycle_count <--. 0; sm.set_next Send_bit_low ]
              ] )
          ; ( State.Send_bit_low
            , [ ws2812_out <--. 0
              ; cycle_count <-- cycle_count.value +:. 1
              ; when_
                  (cycle_count.value >=: low_time -:. 1)
                  [ cycle_count <--. 0; sm.set_next Next_bit ]
              ] )
          ; ( State.Next_bit
            , [ ws2812_out <--. 0
              ; pixel_shift_reg <-- sll pixel_shift_reg.value 1
              ; bit_index <-- bit_index.value +:. 1
              ; if_
                  (bit_index.value ==:. bits_per_pixel - 1)
                  [ sm.set_next Next_pixel ]
                  [ sm.set_next Send_bit_high ]
              ] )
          ; ( State.Next_pixel
            , [ ws2812_out <--. 0
              ; pixel_index <-- pixel_index.value +:. 1
              ; if_
                  (pixel_index.value ==: i.pixel_count -:. 1)
                  [ cycle_count <--. 0; sm.set_next Reset_pulse ]
                  [ (* Pre-fetch next pixel *)
                    read_addr <-- pixel_index.value +:. 1
                  ; read_enable <--. 1
                  ; sm.set_next Load_pixel
                  ]
              ] )
          ; ( State.Reset_pulse
            , [ ws2812_out <--. 0
              ; cycle_count <-- cycle_count.value +:. 1
              ; when_
                  (cycle_count.value >=:. reset_cycles - 1)
                  [ cycle_count <--. 0; sm.set_next Done ]
              ] )
          ; ( State.Done
            , [ ws2812_out <--. 0
              ; done_flag <--. 1
              ; sm.set_next Idle
              ] )
          ]
      ]);
  (* Busy when not in Idle or Done states *)
  let busy = ~:(sm.is State.Idle |: sm.is State.Done) in
  { O.ws2812_out = ws2812_out.value -- "ws2812_out"
  ; busy = busy -- "busy"
  ; done_ = done_flag.value -- "done"
  ; read_addr = read_addr.value -- "read_addr"
  ; read_enable = read_enable.value -- "read_enable"
  }
;;
