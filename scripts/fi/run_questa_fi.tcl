# ==============================================================================
# Proyecto: HPicoRV32 — Motor de campaña SEU externa en Questa (force -deposit)
# Uso:      vsim -c -lib <work> -voptargs="+acc" -GENABLE_TMR=1 -GENABLE_REG_ECC=1 \
#                tb_fi_soc -do scripts/fi/run_questa_fi.tcl
# ==============================================================================

onbreak {resume}

# Lee parámetros desde variables de entorno (evita problemas de comillas en -do)
proc get_env {name default_val} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_val
}

set cfg_tmr      [get_env FI_TMR            1]
set cfg_ecc      [get_env FI_ECC            1]
set targets_file [get_env FI_TARGETS        "build/fi_targets/targets_tmr${cfg_tmr}_ecc${cfg_ecc}.tsv"]
set out_csv      [get_env FI_OUT_CSV        "build/fi_results/pilot_tmr${cfg_tmr}_ecc${cfg_ecc}.csv"]
set num_runs     [get_env FI_NUM_RUNS       20]
set k_faults     [get_env FI_FAULTS_PER_RUN 1]
set base_seed    [get_env FI_SEED           42]
set run_offset   [get_env FI_RUN_OFFSET     0]

# Carga del catálogo plano (1 fila = 1 bit físico)
set targets {}
set fp [open $targets_file r]
while {[gets $fp line] >= 0} {
    if {$line eq ""} continue
    lappend targets [split $line "\t"]
}
close $fp
set num_targets [llength $targets]
puts "=== FI Questa: TMR=$cfg_tmr ECC=$cfg_ecc | K=${k_faults}-SEU | N=$num_runs | targets=$num_targets | seed=$base_seed ==="

# Autoverificación inicial: comprueba que el 100 % de las rutas existen en Questa
set bad_paths 0
foreach t $targets {
    set p [lindex $t 1]
    if {[catch {examine -radix binary $p} err]} {
        puts "ERROR: ruta invalida en catalogo -> $p ($err)"
        incr bad_paths
        if {$bad_paths >= 10} break
    }
}
if {$bad_paths > 0} {
    puts "ABORTANDO: se encontraron rutas invalidas en $targets_file"
    quit -f -code 1
}
puts "  Autoverificacion OK: $num_targets/$num_targets rutas accesibles."

# Distancia de Hamming entre dos cadenas hex de igual longitud (soporta 32b y 39b)
set POPCOUNT [list 0 1 1 2 1 2 2 3 1 2 2 3 2 3 3 4]
proc hex_hamming {h1 h2} {
    global POPCOUNT
    set s1 [string tolower $h1]
    set s2 [string tolower $h2]
    set len [string length $s1]
    set d 0
    for {set i 0} {$i < $len} {incr i} {
        set c1 [string index $s1 $i]
        set c2 [string index $s2 $i]
        if {$c1 ne $c2} {
            if {![string is xdigit $c1] || ![string is xdigit $c2]} {
                return 99
            }
            scan $c1 %x v1
            scan $c2 %x v2
            incr d [lindex $POPCOUNT [expr {$v1 ^ $v2}]]
        }
    }
    return $d
}

# Captura estado arquitectónico: reg_pc + cpuregs[1..31]
proc capture_arch_state {} {
    set pc [examine -radix hex /tb_fi_soc/uut/cpu/reg_pc]
    set regs {}
    for {set r 1} {$r <= 31} {incr r} {
        lappend regs [examine -radix hex "/tb_fi_soc/uut/cpu/cpuregs\[$r\]"]
    }
    return [list $pc $regs]
}

# Comprueba si algún contador TMR/ECC del core o memorias se incrementó (> 0)
proc check_telem_nonzero {tmr ecc} {
    set sigs [list \
        /tb_fi_soc/uut/count_ecc_imem_sbu /tb_fi_soc/uut/count_ecc_imem_dbu \
        /tb_fi_soc/uut/count_ecc_dmem_sbu /tb_fi_soc/uut/count_ecc_dmem_dbu]
    if {$tmr} {
        lappend sigs /tb_fi_soc/uut/cpu/count_tmr_pc /tb_fi_soc/uut/cpu/count_tmr_ctrl
    }
    if {$ecc} {
        lappend sigs /tb_fi_soc/uut/cpu/count_ecc_reg_sbu /tb_fi_soc/uut/cpu/count_ecc_reg_dbu
    }
    foreach s $sigs {
        if {[examine -radix unsigned $s] > 0} { return 1 }
    }
    return 0
}

# Armado de triggers de parada: done_flag o trap_flag
proc arm_stop_triggers {} {
    nowhen *
    when -label stop_done {/tb_fi_soc/done_flag == 1} { stop }
    when -label stop_trap {/tb_fi_soc/trap_flag == 1} { stop }
}

# --- ETAPA 0: GOLDEN RUN (sin fallos) ---
arm_stop_triggers
run 2000us

set g_done [examine -radix unsigned /tb_fi_soc/done_flag]
set g_trap [examine -radix unsigned /tb_fi_soc/trap_flag]
if {$g_done != 1 || $g_trap != 0} {
    puts "ERROR: Golden run fallo (done=$g_done, trap=$g_trap)"
    quit -f -code 1
}

set warmup_cycle   [examine -radix unsigned /tb_fi_soc/warmup_cycle]
set golden_cycles  [examine -radix unsigned /tb_fi_soc/cycle_cnt]
set golden_ulen    [examine -radix unsigned /tb_fi_soc/uart_len]
set golden_ubytes  [examine -radix hex      /tb_fi_soc/uart_bytes]
set g_arch         [capture_arch_state]
set golden_pc      [lindex $g_arch 0]
set golden_regs    [lindex $g_arch 1]

set inj_min        [expr {$warmup_cycle + 1}]
set inj_max        [expr {$golden_cycles - 1}]
set inj_span       [expr {$inj_max - $inj_min + 1}]
set timeout_cycles [expr {$golden_cycles * 3}]

puts "  GOLDEN OK: warmup=$warmup_cycle | total=$golden_cycles | ventana=\[$inj_min..$inj_max\] | timeout=$timeout_cycles | uart_len=$golden_ulen"

# Preparar fichero CSV de salida
file mkdir [file dirname $out_csv]
set csv_fp [open $out_csv w]
puts $csv_fp "run_id,tmr,ecc,faults_per_run,seed,outcome,uart_match,regs_logic_match,regs_phys_match,pc_match,trap_flag,trap_cause,cycles,telem_changed,inj_cycles,inj_regs,inj_bits,inj_domains,inj_is_telem"