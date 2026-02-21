open Hardcaml

(** Verilog generation script.

    Creates the circuit from Top.ml and writes Verilog to
    fpga/generated/ws2812_top.v
*)

let () =
  let scope = Scope.create ~flatten_design:true () in
  let circuit = Ws2812_controller.Top.circuit scope in
  let output_dir = "../../generated" in
  (* Ensure output directory exists *)
  (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let output_path = Stdlib.Filename.concat output_dir "ws2812_top.v" in
  let oc = Stdlib.open_out output_path in
  Rtl.print Verilog ~output:(Rtl.Output.to_channel oc) circuit;
  Stdlib.close_out oc;
  Stdlib.Printf.printf "Generated Verilog: %s\n" output_path
;;
