open Hardcaml

(** Verilog generation script.

    Creates the circuit from Top.ml and writes Verilog to
    fpga/generated/ws2812_top.v

    Output path is determined relative to the project root by finding
    the dune-project file and navigating from there.
*)

let () =
  let scope = Scope.create ~flatten_design:true () in
  let circuit = Ws2812_controller.Top.circuit scope in
  (* Navigate from CWD to the generated/ directory.
     When run via 'dune exec bin/generate.exe' from fpga/hardcaml/,
     CWD is fpga/hardcaml/. *)
  let output_dir = Sys.getenv_opt "OUTPUT_DIR" |> Option.value ~default:"../generated" in
  (try Unix.mkdir output_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let output_path = Stdlib.Filename.concat output_dir "ws2812_top.v" in
  Rtl.output ~output_mode:(To_file output_path) Verilog circuit;
  Stdlib.Printf.printf "Generated Verilog: %s\n" output_path
;;
