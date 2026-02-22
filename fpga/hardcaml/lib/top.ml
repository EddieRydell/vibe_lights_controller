open! Base
open Hardcaml
open Signal

(** Top-level module: AXI-Lite slave + 8-channel WS2812 serializer.

    This module wires together:
    - AXI-Lite register interface (control/status + pixel buffer writes)
    - 8-channel WS2812 multi-serializer
    - External WS2812 data output pins

    Exposes: AXI-Lite port signals + 8 ws2812_data output pins.
    This is what gets compiled to Verilog.
*)

module I = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    ; (* AXI-Lite slave port *)
      s_axi_awaddr : 'a [@bits 16]
    ; s_axi_awvalid : 'a
    ; s_axi_wdata : 'a [@bits 32]
    ; s_axi_wstrb : 'a [@bits 4]
    ; s_axi_wvalid : 'a
    ; s_axi_bready : 'a
    ; s_axi_araddr : 'a [@bits 16]
    ; s_axi_arvalid : 'a
    ; s_axi_rready : 'a
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { (* AXI-Lite slave response *)
      s_axi_awready : 'a
    ; s_axi_wready : 'a
    ; s_axi_bresp : 'a [@bits 2]
    ; s_axi_bvalid : 'a
    ; s_axi_arready : 'a
    ; s_axi_rdata : 'a [@bits 32]
    ; s_axi_rresp : 'a [@bits 2]
    ; s_axi_rvalid : 'a
    ; (* WS2812 outputs *)
      ws2812_out : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create (scope : Scope.t) (i : _ I.t) =
  let axi_scope = Scope.sub_scope scope "axi" in
  let multi_scope = Scope.sub_scope scope "multi" in
  (* Wire up the AXI register block *)
  let from_ws2812 =
    { Axi_registers.From_ws2812.busy = wire 1
    ; done_ = wire 1
    ; channel_busy = wire 8
    }
  in
  let axi_out, to_ws2812 =
    Axi_registers.create
      axi_scope
      { Axi_registers.Axi_lite.I.clock = i.clock
      ; clear = i.clear
      ; awaddr = i.s_axi_awaddr
      ; awvalid = i.s_axi_awvalid
      ; wdata = i.s_axi_wdata
      ; wstrb = i.s_axi_wstrb
      ; wvalid = i.s_axi_wvalid
      ; bready = i.s_axi_bready
      ; araddr = i.s_axi_araddr
      ; arvalid = i.s_axi_arvalid
      ; rready = i.s_axi_rready
      }
      from_ws2812
  in
  (* Wire up the multi-channel WS2812 block *)
  let multi_out =
    Ws2812_multi.create
      multi_scope
      { Ws2812_multi.I.clock = i.clock
      ; clear = i.clear
      ; start = to_ws2812.start
      ; pixel_counts = to_ws2812.pixel_counts
      ; pixel_format = to_ws2812.pixel_format
      ; channel_enable = to_ws2812.channel_enable
      ; buf_write_enable = to_ws2812.buf_write_enable
      ; buf_write_addr = to_ws2812.buf_write_addr
      ; buf_write_data = to_ws2812.buf_write_data
      }
  in
  (* Connect feedback from WS2812 block back to AXI status registers *)
  from_ws2812.busy <== multi_out.busy;
  from_ws2812.done_ <== multi_out.done_;
  from_ws2812.channel_busy <== multi_out.channel_busy;
  { O.s_axi_awready = axi_out.awready
  ; s_axi_wready = axi_out.wready
  ; s_axi_bresp = axi_out.bresp
  ; s_axi_bvalid = axi_out.bvalid
  ; s_axi_arready = axi_out.arready
  ; s_axi_rdata = axi_out.rdata
  ; s_axi_rresp = axi_out.rresp
  ; s_axi_rvalid = axi_out.rvalid
  ; ws2812_out = multi_out.ws2812_out
  }
;;

let circuit scope =
  let module C =
    Circuit.With_interface (I) (O)
  in
  C.create_exn ~name:"ws2812_top" (create scope)
;;
