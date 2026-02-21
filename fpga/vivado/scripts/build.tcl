##############################################################################
## Vivado TCL Build Script — WS2812 Controller on PYNQ-Z2
##
## Usage:
##   vivado -mode batch -source build.tcl
##
## This script:
##   1. Creates a Vivado project targeting xc7z020clg400-1
##   2. Adds the HardCaml-generated Verilog as a design source
##   3. Creates a block design with Zynq PS7 + WS2812 IP
##   4. Runs synthesis, implementation, and bitstream generation
##   5. Exports bitstream and hardware handoff files
##############################################################################

set project_name "ws2812_pynq"
set project_dir  [file normalize "../../output/vivado_project"]
set gen_dir      [file normalize "../../generated"]
set constraints  [file normalize "../constraints/pynq_z2.xdc"]
set output_dir   [file normalize "../../output"]

# Step 1: Create project
create_project $project_name $project_dir -part xc7z020clg400-1 -force

# Set board part (PYNQ-Z2) — requires board files installed
# TUL PYNQ-Z2 board file identifier
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]

# Step 2: Add generated Verilog source
add_files -norecurse [file normalize "$gen_dir/ws2812_top.v"]
update_compile_order -fileset sources_1

# Step 3: Create block design
create_bd_design "system"

# Add Zynq PS7 and apply board preset
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
apply_board_connection -board_interface "ddr" -ip_intf "ps7/DDR" -diagram "system"
apply_board_connection -board_interface "fixed_io" -ip_intf "ps7/FIXED_IO" -diagram "system"

# Configure PS7: enable M_AXI_GP0, set FCLK_CLK0 to 100 MHz
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] [get_bd_cells ps7]

# Add the WS2812 RTL module to block design
create_bd_cell -type module -reference ws2812_top ws2812_top_0

# Add AXI Interconnect
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property -dict [list CONFIG.NUM_MI {1}] [get_bd_cells axi_interconnect_0]

# Add Processor System Reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

# Connect clocks
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ws2812_top_0/clock] \
    [get_bd_pins axi_interconnect_0/ACLK] \
    [get_bd_pins axi_interconnect_0/S00_ACLK] \
    [get_bd_pins axi_interconnect_0/M00_ACLK] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# Connect resets
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN] \
    [get_bd_pins axi_interconnect_0/S00_ARESETN] \
    [get_bd_pins axi_interconnect_0/M00_ARESETN]

# Note: ws2812_top uses active-high clear (not aresetn).
# Invert the reset for it.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 reset_inv
set_property -dict [list \
    CONFIG.C_SIZE {1} \
    CONFIG.C_OPERATION {not} \
] [get_bd_cells reset_inv]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
    [get_bd_pins reset_inv/Op1]
connect_bd_net [get_bd_pins reset_inv/Res] \
    [get_bd_pins ws2812_top_0/clear]

# Connect AXI interfaces
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]

# Connect AXI interconnect master to WS2812 slave signals manually
# (since ws2812_top doesn't use standard AXI interface naming from hardcaml)
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awaddr] \
    [get_bd_pins ws2812_top_0/s_axi_awaddr]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awvalid] \
    [get_bd_pins ws2812_top_0/s_axi_awvalid]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awready] \
    [get_bd_pins ws2812_top_0/s_axi_awready]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wdata] \
    [get_bd_pins ws2812_top_0/s_axi_wdata]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wstrb] \
    [get_bd_pins ws2812_top_0/s_axi_wstrb]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wvalid] \
    [get_bd_pins ws2812_top_0/s_axi_wvalid]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wready] \
    [get_bd_pins ws2812_top_0/s_axi_wready]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bresp] \
    [get_bd_pins ws2812_top_0/s_axi_bresp]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bvalid] \
    [get_bd_pins ws2812_top_0/s_axi_bvalid]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bready] \
    [get_bd_pins ws2812_top_0/s_axi_bready]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_araddr] \
    [get_bd_pins ws2812_top_0/s_axi_araddr]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_arvalid] \
    [get_bd_pins ws2812_top_0/s_axi_arvalid]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_arready] \
    [get_bd_pins ws2812_top_0/s_axi_arready]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rdata] \
    [get_bd_pins ws2812_top_0/s_axi_rdata]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rresp] \
    [get_bd_pins ws2812_top_0/s_axi_rresp]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rvalid] \
    [get_bd_pins ws2812_top_0/s_axi_rvalid]
connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rready] \
    [get_bd_pins ws2812_top_0/s_axi_rready]

# Make WS2812 output pins external
make_bd_pins_external [get_bd_pins ws2812_top_0/ws2812_out]
set_property name ws2812_out [get_bd_ports ws2812_out_0]

# Assign address: ws2812_top at 0x43C0_0000, 64 KB range
assign_bd_address
set_property offset 0x43C00000 [get_bd_addr_segs {ps7/Data/SEG_ws2812_top_0*}]
set_property range 64K [get_bd_addr_segs {ps7/Data/SEG_ws2812_top_0*}]

# Validate and save block design
validate_bd_design
save_bd_design

# Step 4: Add constraints
add_files -fileset constrs_1 -norecurse $constraints

# Step 5: Generate HDL wrapper
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file normalize "$project_dir/$project_name.gen/sources_1/bd/system/hdl/system_wrapper.v"]
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]

# Step 6: Run synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    error "Synthesis failed!"
}

# Step 7: Run implementation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] != "write_bitstream Complete!"} {
    error "Implementation/bitstream generation failed!"
}

# Step 8: Copy output files
file mkdir $output_dir
file copy -force \
    [file normalize "$project_dir/$project_name.runs/impl_1/system_wrapper.bit"] \
    [file normalize "$output_dir/system.bit"]

# Export hardware handoff
write_hwdef -force -file [file normalize "$output_dir/system.hwh"]

puts "Build complete!"
puts "Bitstream: $output_dir/system.bit"
puts "Hardware handoff: $output_dir/system.hwh"
