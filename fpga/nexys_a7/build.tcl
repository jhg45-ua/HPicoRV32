# ==============================================================================
# Proyecto: HPicoRV32 (Hardened PicoRV32)
# Script:   build.tcl — Síntesis, implementación y bitstream en modo batch
# ==============================================================================

set script_dir [file dirname [file normalize [info script]]]
source "$script_dir/create_project.tcl"

# 1. Síntesis
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "ERROR: La síntesis de Vivado ha fallado."
}

# 2. Implementación y generación de bitstream
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "ERROR: La implementación o generación de bitstream ha fallado."
}

# 3. Exportar informes y copiar bitstream a ruta fija
open_run impl_1
report_utilization    -file "$proj_dir/utilization.rpt"
report_timing_summary -file "$proj_dir/timing.rpt"

# Toma top_module definido en create_project.tcl ('soc' si FI=0, 'soc_fi_top' si FI=1) y lo
# copia a una ruta fija hpicorv32.bit para que 'make prog' lo encuentre siempre igual.
set bit_src "$proj_dir/${proj_name}.runs/impl_1/${top_module}.bit"
set bit_dst "$proj_dir/hpicorv32.bit"
file copy -force $bit_src $bit_dst

puts "INFO: Bitstream listo en $bit_dst"
puts "INFO: Informes guardados en $proj_dir/utilization.rpt y timing.rpt"
