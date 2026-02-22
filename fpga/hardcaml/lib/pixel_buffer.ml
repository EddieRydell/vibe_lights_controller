open! Base
open Hardcaml

(** Dual-port pixel data storage.

    Port A: AXI write side — 32-bit words addressed by AXI bus offset.
    Port B: Serializer read side — 32-bit pixel data addressed by pixel index.

    Each pixel is stored as a 32-bit word. For RGB mode the lower 24 bits
    contain color data; for RGBW mode all 32 bits are used.
    Maximum 1024 pixels per channel (limited by 4 KB address space).
*)

let max_pixels = 1024

module Write_port = struct
  type 'a t =
    { clock : 'a
    ; write_enable : 'a
    ; write_addr : 'a [@bits 10]
    ; write_data : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module Read_port = struct
  type 'a t =
    { clock : 'a
    ; read_enable : 'a
    ; read_addr : 'a [@bits 10]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { read_data : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (_scope : Scope.t) (write : _ Write_port.t) (read : _ Read_port.t) =
  (* Simple dual-port RAM: one write port, one read port.
     Ram.create uses Hardcaml.Write_port.t and Hardcaml.Read_port.t records. *)
  let read_data_arr =
    Ram.create
      ~collision_mode:Read_before_write
      ~size:max_pixels
      ~write_ports:
        [| { Hardcaml.Write_port.write_clock = write.clock
           ; write_address = write.write_addr
           ; write_data = write.write_data
           ; write_enable = write.write_enable
           }
        |]
      ~read_ports:
        [| { Hardcaml.Read_port.read_clock = read.clock
           ; read_address = read.read_addr
           ; read_enable = read.read_enable
           }
        |]
      ()
  in
  (* Return full 32 bits — serializer handles RGB vs RGBW alignment *)
  { O.read_data = read_data_arr.(0) }
;;
