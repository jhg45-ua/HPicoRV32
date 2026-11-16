# ==============================================================================
# Proyecto: SHRV32 (Space-Hardened RISC-V 32)
# Script:   create_project.tcl — Crea el proyecto Vivado en build/vivado/
# ==============================================================================

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize "$script_dir/../.."]
set proj_dir   "$repo_root/build/vivado"
set proj_name  "shrv32"
set part_name  "xc7a100tcsg324-1"

file mkdir $proj_dir

# Crear proyecto limpio sin copiar los fuentes a build/
create_project -force $proj_name $proj_dir -part $part_name

# Añadir módulos RTL sintetizables por subcarpetas
set rtl_files [concat \
    [glob -nocomplain "$repo_root/rtl/core/*.v"] \
    [glob -nocomplain "$repo_root/rtl/mem/*.v"] \
    [glob -nocomplain "$repo_root/rtl/periph/*.v"] \
    [glob -nocomplain "$repo_root/rtl/top/*.v"] \
]

if {[llength $rtl_files] > 0} {
    add_files -fileset sources_1 -norecurse $rtl_files
}

# Añadir firmware.hex si ya está compilado y marcarlo como Memory Initialization File
set hex_file "$repo_root/build/firmware.hex"
if {[file exists $hex_file]} {
    add_files -fileset sources_1 -norecurse $hex_file
    set_property file_type {Memory Initialization Files} [get_files $hex_file]
}

# IP oficial Block Memory Generator con Soft ECC para DMEM (2048x32b, Simple Dual-Port, sin .coe)
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name blk_mem_gen_dmem_ecc
set_property -dict [list \
    CONFIG.Memory_Type {Simple_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {2048} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.ECC {false} \
    CONFIG.ecctype {Soft_ECC} \
    CONFIG.softecc {true} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Core {false} \
    CONFIG.register_porta_input_of_softecc {false} \
    CONFIG.register_portb_output_of_softecc {false} \
] [get_ips blk_mem_gen_dmem_ecc]
generate_target {synthesis simulation} [get_ips blk_mem_gen_dmem_ecc]

# En síntesis (sources_1) DMEM usa la IP ECC de Vivado; en sim_1 usa RTL para inyección XOR
set_property verilog_define {VIVADO_MEM_INIT=1 VIVADO_ECC_IP=1} [get_filesets sources_1]
set_property verilog_define {VIVADO_MEM_INIT=1} [get_filesets sim_1]

# Definir módulo raíz (Top-Level)
set_property top soc [current_fileset]

# Añadir archivo de restricciones de la Nexys A7-100T
set xdc_file "$script_dir/Nexys-A7-100T-Master.xdc"
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
}

# Añadir testbenches al conjunto de simulación
set tb_files [glob -nocomplain "$repo_root/tb/*.v"]
if {[llength $tb_files] > 0} {
    add_files -fileset sim_1 -norecurse $tb_files
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "INFO: Proyecto Vivado generado en $proj_dir/$proj_name.xpr"
