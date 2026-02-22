open! Base
open Hardcaml
open Signal

(** AXI-Lite register map for the WS2812 controller (v2.0.0).

    Register layout:
    - 0x0000 CTRL:          Bit 0 = start, Bit 1 = auto_repeat (R/W)
    - 0x0004 STATUS:        Bit 0 = busy, Bit 1 = done (R)
    - 0x0008 PIX_COUNT:     Backward compat alias for CH0 pixel count (R/W)
    - 0x000C CH_ENABLE:     Channel enable bitmask (R/W)
    - 0x0010 VERSION:       Hardcoded version (R)
    - 0x0014 CH0_PIX_COUNT: Channel 0 pixel count, 1-1024 (R/W)
    - 0x0018 CH1_PIX_COUNT: Channel 1 pixel count (R/W)
    - 0x001C CH2_PIX_COUNT: Channel 2 pixel count (R/W)
    - 0x0020 CH3_PIX_COUNT: Channel 3 pixel count (R/W)
    - 0x0024 CH4_PIX_COUNT: Channel 4 pixel count (R/W)
    - 0x0028 CH5_PIX_COUNT: Channel 5 pixel count (R/W)
    - 0x002C CH6_PIX_COUNT: Channel 6 pixel count (R/W)
    - 0x0030 CH7_PIX_COUNT: Channel 7 pixel count (R/W)
    - 0x0034 PIX_FMT:       Per-channel RGBW mode bitmask (R/W)
    - 0x1000-0x13FC CH0_DATA: Channel 0 pixel buffer
    - 0x2000-0x23FC CH1_DATA: Channel 1 pixel buffer
    - ...
    - 0x8000-0x83FC CH7_DATA: Channel 7 pixel buffer

    Address decoding:
    - Bits [15:12] select region: 0 = control regs, 1-8 = channel data
    - For control regs, bits [6:2] select the register (5 bits, 32 registers)
    - For channel data, bits [11:2] select the pixel word index
*)

let version_id = 0x00_02_00_00  (* v2.0.0 *)

module Axi_lite = struct
  (** AXI-Lite slave port signals *)
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; (* AXI Write Address channel *)
        awaddr : 'a [@bits 16]
      ; awvalid : 'a
      ; (* AXI Write Data channel *)
        wdata : 'a [@bits 32]
      ; wstrb : 'a [@bits 4]
      ; wvalid : 'a
      ; (* AXI Write Response channel *)
        bready : 'a
      ; (* AXI Read Address channel *)
        araddr : 'a [@bits 16]
      ; arvalid : 'a
      ; (* AXI Read Data channel *)
        rready : 'a
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t =
      { (* AXI Write Address channel *)
        awready : 'a
      ; (* AXI Write Data channel *)
        wready : 'a
      ; (* AXI Write Response channel *)
        bresp : 'a [@bits 2]
      ; bvalid : 'a
      ; (* AXI Read Address channel *)
        arready : 'a
      ; (* AXI Read Data channel *)
        rdata : 'a [@bits 32]
      ; rresp : 'a [@bits 2]
      ; rvalid : 'a
      }
    [@@deriving hardcaml]
  end
end

(** Decoded register interface to/from the multi-channel WS2812 block *)
module To_ws2812 = struct
  type 'a t =
    { start : 'a
    ; auto_repeat : 'a
    ; pixel_counts : 'a list [@length 8] [@bits 10]  (** Per-channel pixel counts *)
    ; pixel_format : 'a [@bits 8]  (** Per-channel RGBW mode bitmask *)
    ; channel_enable : 'a [@bits 8]
    ; buf_write_enable : 'a [@bits 8]
    ; buf_write_addr : 'a [@bits 10]
    ; buf_write_data : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module From_ws2812 = struct
  type 'a t =
    { busy : 'a
    ; done_ : 'a
    ; channel_busy : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

(** AXI-Lite state machine states *)
module Wr_state = struct
  type t =
    | Wr_idle
    | Wr_data
    | Wr_resp
  [@@deriving sexp_of, compare, enumerate]
end

module Rd_state = struct
  type t =
    | Rd_idle
    | Rd_data
  [@@deriving sexp_of, compare, enumerate]
end

let create (scope : Scope.t) (axi : _ Axi_lite.I.t) (from_ws : _ From_ws2812.t) =
  let ( -- ) = Scope.naming scope in
  let spec = Reg_spec.create ~clock:axi.clock ~clear:axi.clear () in
  (* Write state machine *)
  let wr_sm = Always.State_machine.create (module Wr_state) spec ~enable:vdd in
  let wr_addr = Always.Variable.reg spec ~enable:vdd ~width:16 in
  (* Read state machine *)
  let rd_sm = Always.State_machine.create (module Rd_state) spec ~enable:vdd in
  let rd_addr = Always.Variable.reg spec ~enable:vdd ~width:16 in
  let rd_data = Always.Variable.reg spec ~enable:vdd ~width:32 in
  (* Control registers *)
  let ctrl_reg = Always.Variable.reg spec ~enable:vdd ~width:32 in
  let ch_enable_reg = Always.Variable.reg spec ~enable:vdd ~width:8 in
  (* Per-channel pixel count registers *)
  let ch_pix_count_regs =
    Array.init 8 ~f:(fun _i -> Always.Variable.reg spec ~enable:vdd ~width:10)
  in
  (* Pixel format register (per-channel RGBW mode) *)
  let pix_fmt_reg = Always.Variable.reg spec ~enable:vdd ~width:8 in
  (* Start pulse: one-shot from bit 0 of CTRL write *)
  let start_pulse = Always.Variable.reg spec ~enable:vdd ~width:1 in
  (* Buffer write signals *)
  let buf_we = Always.Variable.reg spec ~enable:vdd ~width:8 in
  let buf_waddr = Always.Variable.reg spec ~enable:vdd ~width:10 in
  let buf_wdata = Always.Variable.reg spec ~enable:vdd ~width:32 in
  (* Address decoding helpers *)
  let wr_region = select wr_addr.value 15 12 in
  let wr_reg_sel = select wr_addr.value 6 2 in  (* 5 bits: 32 register slots *)
  let wr_pixel_idx = select wr_addr.value 11 2 in
  Always.(
    compile
      [ (* Default: clear one-shot signals *)
        start_pulse <--. 0
      ; buf_we <--. 0
      ; (* Write state machine *)
        wr_sm.switch
          [ ( Wr_state.Wr_idle
            , [ when_
                  axi.awvalid
                  [ wr_addr <-- axi.awaddr; wr_sm.set_next Wr_data ]
              ] )
          ; ( Wr_state.Wr_data
            , [ when_
                  axi.wvalid
                  [ (* Decode write address *)
                    if_
                      (wr_region ==:. 0)
                      [ (* Control register space: decode bits [6:2] *)
                        switch
                          wr_reg_sel
                          [ ( of_int ~width:5 0  (* 0x00: CTRL *)
                            , [ ctrl_reg <-- axi.wdata
                              ; start_pulse <-- bit axi.wdata 0
                              ] )
                          ; ( of_int ~width:5 2  (* 0x08: PIX_COUNT — backward compat alias for CH0 *)
                            , [ ch_pix_count_regs.(0) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 3  (* 0x0C: CH_ENABLE *)
                            , [ ch_enable_reg <-- select axi.wdata 7 0 ] )
                          (* 0x10: VERSION is read-only, writes ignored *)
                          ; ( of_int ~width:5 5  (* 0x14: CH0_PIX_COUNT *)
                            , [ ch_pix_count_regs.(0) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 6  (* 0x18: CH1_PIX_COUNT *)
                            , [ ch_pix_count_regs.(1) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 7  (* 0x1C: CH2_PIX_COUNT *)
                            , [ ch_pix_count_regs.(2) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 8  (* 0x20: CH3_PIX_COUNT *)
                            , [ ch_pix_count_regs.(3) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 9  (* 0x24: CH4_PIX_COUNT *)
                            , [ ch_pix_count_regs.(4) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 10  (* 0x28: CH5_PIX_COUNT *)
                            , [ ch_pix_count_regs.(5) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 11  (* 0x2C: CH6_PIX_COUNT *)
                            , [ ch_pix_count_regs.(6) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 12  (* 0x30: CH7_PIX_COUNT *)
                            , [ ch_pix_count_regs.(7) <-- select axi.wdata 9 0 ] )
                          ; ( of_int ~width:5 13  (* 0x34: PIX_FMT *)
                            , [ pix_fmt_reg <-- select axi.wdata 7 0 ] )
                          ]
                      ]
                      [ (* Channel data space: region 1-8 maps to channel 0-7 *)
                        buf_waddr <-- wr_pixel_idx
                      ; buf_wdata <-- axi.wdata
                      ; (* Decode channel from region and set per-channel write enable *)
                        switch
                          wr_region
                          [ of_int ~width:4 1, [ buf_we <--. 0x01 ]
                          ; of_int ~width:4 2, [ buf_we <--. 0x02 ]
                          ; of_int ~width:4 3, [ buf_we <--. 0x04 ]
                          ; of_int ~width:4 4, [ buf_we <--. 0x08 ]
                          ; of_int ~width:4 5, [ buf_we <--. 0x10 ]
                          ; of_int ~width:4 6, [ buf_we <--. 0x20 ]
                          ; of_int ~width:4 7, [ buf_we <--. 0x40 ]
                          ; of_int ~width:4 8, [ buf_we <--. 0x80 ]
                          ]
                      ]
                  ; wr_sm.set_next Wr_resp
                  ]
              ] )
          ; ( Wr_state.Wr_resp
            , [ when_ axi.bready [ wr_sm.set_next Wr_idle ] ] )
          ]
      ; (* Read state machine *)
        rd_sm.switch
          [ ( Rd_state.Rd_idle
            , [ when_
                  axi.arvalid
                  [ rd_addr <-- axi.araddr
                  ; (* Decode read address and set read data *)
                    if_
                      (select axi.araddr 15 12 ==:. 0)
                      [ (* Control register space: decode bits [6:2] *)
                        switch
                          (select axi.araddr 6 2)
                          [ ( of_int ~width:5 0  (* 0x00: CTRL *)
                            , [ rd_data <-- uresize ctrl_reg.value 32 ] )
                          ; ( of_int ~width:5 1  (* 0x04: STATUS *)
                            , [ rd_data
                                <-- uresize
                                      (from_ws.done_ @: from_ws.busy) 32
                              ] )
                          ; ( of_int ~width:5 2  (* 0x08: PIX_COUNT — reads CH0 pixel count *)
                            , [ rd_data
                                <-- uresize ch_pix_count_regs.(0).value 32
                              ] )
                          ; ( of_int ~width:5 3  (* 0x0C: CH_ENABLE *)
                            , [ rd_data
                                <-- uresize ch_enable_reg.value 32
                              ] )
                          ; ( of_int ~width:5 4  (* 0x10: VERSION *)
                            , [ rd_data <--. version_id ] )
                          ; ( of_int ~width:5 5  (* 0x14: CH0_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(0).value 32 ] )
                          ; ( of_int ~width:5 6  (* 0x18: CH1_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(1).value 32 ] )
                          ; ( of_int ~width:5 7  (* 0x1C: CH2_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(2).value 32 ] )
                          ; ( of_int ~width:5 8  (* 0x20: CH3_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(3).value 32 ] )
                          ; ( of_int ~width:5 9  (* 0x24: CH4_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(4).value 32 ] )
                          ; ( of_int ~width:5 10  (* 0x28: CH5_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(5).value 32 ] )
                          ; ( of_int ~width:5 11  (* 0x2C: CH6_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(6).value 32 ] )
                          ; ( of_int ~width:5 12  (* 0x30: CH7_PIX_COUNT *)
                            , [ rd_data <-- uresize ch_pix_count_regs.(7).value 32 ] )
                          ; ( of_int ~width:5 13  (* 0x34: PIX_FMT *)
                            , [ rd_data <-- uresize pix_fmt_reg.value 32 ] )
                          ]
                      ]
                      [ (* Channel data reads — return 0 for now (write-only buffers) *)
                        rd_data <--. 0
                      ]
                  ; rd_sm.set_next Rd_data
                  ]
              ] )
          ; ( Rd_state.Rd_data
            , [ when_ axi.rready [ rd_sm.set_next Rd_idle ] ] )
          ]
      ]);
  (* AXI outputs *)
  let axi_out =
    { Axi_lite.O.awready = wr_sm.is Wr_idle -- "awready"
    ; wready = wr_sm.is Wr_data -- "wready"
    ; bresp = zero 2  (* OKAY *)
    ; bvalid = wr_sm.is Wr_resp -- "bvalid"
    ; arready = rd_sm.is Rd_idle -- "arready"
    ; rdata = rd_data.value -- "rdata"
    ; rresp = zero 2  (* OKAY *)
    ; rvalid = rd_sm.is Rd_data -- "rvalid"
    }
  in
  let to_ws =
    { To_ws2812.start = start_pulse.value -- "start_pulse"
    ; auto_repeat = bit ctrl_reg.value 1 -- "auto_repeat"
    ; pixel_counts =
        Array.to_list
          (Array.mapi ch_pix_count_regs ~f:(fun idx reg ->
             reg.value -- Printf.sprintf "pixel_count_ch%d" idx))
    ; pixel_format = pix_fmt_reg.value -- "pixel_format"
    ; channel_enable = ch_enable_reg.value -- "channel_enable"
    ; buf_write_enable = buf_we.value -- "buf_write_enable"
    ; buf_write_addr = buf_waddr.value -- "buf_write_addr"
    ; buf_write_data = buf_wdata.value -- "buf_write_data"
    }
  in
  axi_out, to_ws
;;
