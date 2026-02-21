open! Base
open Hardcaml
open Signal

(** 8-channel WS2812 wrapper.

    Instantiates 8x ws2812_serializer + 8x pixel_buffer.
    Fans out shared control signals (start, pixel_count).
    Collects individual busy/done into aggregate status.

    Uses HardCaml wires to resolve the circular dependency between
    the serializer (needs pixel_data from buffer) and the buffer
    (needs read_addr/read_enable from serializer).
*)

let num_channels = 8

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; start : 'a  (** Pulse to trigger all enabled channels *)
    ; pixel_count : 'a [@bits 10]  (** Pixels per channel *)
    ; channel_enable : 'a [@bits 8]  (** Bitmask of active channels *)
    ; (* Pixel buffer write interface — active channel selected externally *)
      buf_write_enable : 'a [@bits 8]  (** Per-channel write enable *)
    ; buf_write_addr : 'a [@bits 10]  (** Write address (same for all) *)
    ; buf_write_data : 'a [@bits 32]  (** Write data (same for all) *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ws2812_out : 'a [@bits 8]  (** 8 WS2812 data output pins *)
    ; busy : 'a  (** High if any channel is busy *)
    ; done_ : 'a  (** High when all enabled channels are done *)
    ; channel_busy : 'a [@bits 8]  (** Per-channel busy status *)
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) =
  let ws2812_bits = Array.create ~len:num_channels gnd in
  let busy_bits = Array.create ~len:num_channels gnd in
  let done_bits = Array.create ~len:num_channels vdd in
  for ch = 0 to num_channels - 1 do
    let ch_scope = Scope.sub_scope scope (Printf.sprintf "ch%d" ch) in
    let ch_enabled = bit i.channel_enable ch in
    let ch_start = i.start &: ch_enabled in
    let ch_write_en = bit i.buf_write_enable ch in
    (* Use wires to break the circular dependency:
       serializer needs pixel_data (from buffer read port),
       buffer needs read_addr and read_enable (from serializer). *)
    let pixel_data_wire = wire 24 in
    (* Create serializer — pixel_data is a wire, assigned after buffer creation *)
    let ser_out =
      Ws2812_serializer.create
        (Scope.sub_scope ch_scope "ser")
        { Ws2812_serializer.I.clock = i.clock
        ; clear = i.clear
        ; start = ch_start
        ; pixel_count = i.pixel_count
        ; pixel_data = pixel_data_wire
        }
    in
    (* Create pixel buffer — uses serializer's read_addr/read_enable *)
    let buf_out =
      Pixel_buffer.create
        (Scope.sub_scope ch_scope "buf")
        { Pixel_buffer.Write_port.clock = i.clock
        ; write_enable = ch_write_en
        ; write_addr = i.buf_write_addr
        ; write_data = i.buf_write_data
        }
        { Pixel_buffer.Read_port.clock = i.clock
        ; read_enable = ser_out.read_enable
        ; read_addr = ser_out.read_addr
        }
    in
    (* Close the loop: buffer read_data drives serializer pixel_data *)
    pixel_data_wire <== buf_out.read_data;
    ws2812_bits.(ch) <- ser_out.ws2812_out;
    busy_bits.(ch) <- ser_out.busy;
    done_bits.(ch) <- ser_out.done_
  done;
  let channel_busy = concat_msb_e (Array.to_list busy_bits |> List.rev) in
  let any_busy = reduce ~f:( |: ) (Array.to_list busy_bits) in
  let all_done =
    reduce ~f:( &: )
      (List.init num_channels ~f:(fun ch ->
         (* Channel is "done" if it's either disabled or reports done *)
         ~:(bit i.channel_enable ch) |: done_bits.(ch)))
  in
  let ws2812_out = concat_msb_e (Array.to_list ws2812_bits |> List.rev) in
  { O.ws2812_out; busy = any_busy; done_ = all_done; channel_busy }
;;
