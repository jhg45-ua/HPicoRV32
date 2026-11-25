#!/usr/bin/env python3
"""Generador del catálogo plano de bits secuenciales reales para campañas SEU (HPicoRV32).

Cada fila generada representa exactamente 1 bit físico (FF o bit de cpuregs[1..31]),
garantizando muestreo uniforme a nivel de bit y excluyendo FFs fantasma/podados en síntesis.
"""

import argparse
from pathlib import Path

# Registros protegidos por TMR (en ENABLE_TMR=0 solo existe _r0; en ENABLE_TMR=1 existen _r0,_r1,_r2)
TMR_PC_REGS = [("reg_pc", 32), ("reg_next_pc", 32)]
TMR_CTRL_REGS = [("cpu_state", 8), ("mem_state", 2), ("latched_rd", 5)]

# FFs activos sin proteger dentro de picorv32 (filtrados los 726 bits de debug/IRQ/C/PCPI/64b)
CPU_DATAPATH_REGS = [
    ("reg_op1", 32), ("reg_op2", 32), ("reg_out", 32), ("reg_sh", 5),
    ("decoded_imm", 32), ("decoded_imm_j", 32),
    ("decoded_rd", 5), ("decoded_rs1", 5), ("decoded_rs2", 5),
    ("next_insn_opcode", 32),
]

CPU_MEM_IF_REGS = [
    ("mem_addr", 32), ("mem_wdata", 32), ("mem_rdata_q", 32),
    ("mem_wstrb", 4), ("mem_wordsize", 2),
    ("mem_valid", 1), ("mem_instr", 1),
    ("mem_do_prefetch", 1), ("mem_do_rinst", 1),
    ("mem_do_rdata", 1), ("mem_do_wdata", 1),
]

CPU_TRAP_REGS = [
    ("trap", 1), ("trap_active", 1), ("trap_cause", 4), ("trap_epc", 32),
    ("hard_trap_pulse_o", 1), ("hard_trap_force_o", 1),
]

# Solo los 32 bits bajos están activos (ENABLE_COUNTERS64=0)
CPU_COUNTERS_REGS = [("count_cycle", 32), ("count_instr", 32)]

CPU_DECODER_1BIT = [
    "decoder_trigger", "decoder_trigger_q",
    "decoder_pseudo_trigger", "decoder_pseudo_trigger_q",
    "latched_store", "latched_stalu", "latched_branch",
    "latched_is_lu", "latched_is_lh", "latched_is_lb",
    "instr_add", "instr_addi", "instr_and", "instr_andi", "instr_auipc",
    "instr_beq", "instr_bge", "instr_bgeu", "instr_blt", "instr_bltu", "instr_bne",
    "instr_ecall_ebreak", "instr_fence", "instr_jal", "instr_jalr",
    "instr_lb", "instr_lbu", "instr_lh", "instr_lhu", "instr_lui", "instr_lw",
    "instr_mret", "instr_or", "instr_ori",
    "instr_rdcycle", "instr_rdecc_reg_dbu", "instr_rdecc_reg_sbu", "instr_rdinstr",
    "instr_rdtmr_ctrl", "instr_rdtmr_pc", "instr_rdtrap_cause", "instr_rdtrap_epc",
    "instr_sb", "instr_sh", "instr_sll", "instr_slli", "instr_slt", "instr_slti",
    "instr_sltiu", "instr_sltu", "instr_sra", "instr_srai", "instr_srl", "instr_srli",
    "instr_sub", "instr_sw", "instr_xor", "instr_xori",
    "is_alu_reg_imm", "is_alu_reg_reg", "is_beq_bne_blt_bge_bltu_bgeu", "is_compare",
    "is_jalr_addi_slti_sltiu_xori_ori_andi", "is_lb_lh_lw_lbu_lhu", "is_lbu_lhu_lw",
    "is_lui_auipc_jal", "is_lui_auipc_jal_jalr_addi_add_sub", "is_sb_sh_sw",
    "is_slli_srli_srai", "is_slti_blt_slt", "is_sltiu_bltu_sltu",
]

# Bloques del SoC fuera de la CPU (excluidas matrices físicas imem/dmem u_bram.mem)
SOC_BUS_REGS = [
    ("reset_cnt", 6), ("leds", 15), ("mmio_rdata", 32),
    ("bus_ready_r", 1), ("harv_fault_r", 1), ("ecc_fault_r", 1), ("trap_uart_logged_r", 1),
]
SOC_TELEM_REGS = [
    ("count_ecc_imem_sbu", 32), ("count_ecc_imem_dbu", 32),
    ("count_ecc_dmem_sbu", 32), ("count_ecc_dmem_dbu", 32),
]
BRAM_IMEM_CTRL_REGS = [
    ("state", 3), ("addr_q", 11), ("scrub_word_q", 39),
    ("rdata_o", 32), ("ready_o", 1), ("sbe_o", 1), ("dbe_o", 1),
]
BRAM_DMEM_CTRL_REGS = BRAM_IMEM_CTRL_REGS + [
    ("wstrb_q", 4), ("wdata_q", 32), ("rmw_base_q", 32),
]
UART_REGS = [
    ("cfg_divider", 32), ("send_pattern", 10), ("send_bitcnt", 4),
    ("send_divcnt", 32), ("send_dummy", 1),
    ("recv_state", 4), ("recv_divcnt", 32), ("recv_pattern", 8),
    ("recv_buf_data", 8), ("recv_buf_valid", 1),
]
FATAL_TX_REGS = [("state", 1), ("idx", 8), ("cause_r", 4), ("epc_r", 32)]

def expand_regs(rows, prefix, mod_tag, regs, domain, is_telem=0):
    """Añade una entrada por cada bit del registro (sin [0] en escalares de 1 bit)."""
    for name, width in regs:
        reg_label = f"{mod_tag}.{name}" if mod_tag else name
        if width == 1:
            rows.append((f"{prefix}/{name}", reg_label, 0, domain, is_telem))
        else:
            for bit in range(width):
                rows.append((f"{prefix}/{name}[{bit}]", reg_label, bit, domain, is_telem))


def build_targets(tmr: int, ecc: int, root: str = "/tb_fi_soc/uut"):
    rows = []
    cpu = f"{root}/cpu"

    # 1. Registros TMR (3 copias si ENABLE_TMR=1; solo _r0 si ENABLE_TMR=0)
    reps = ("r0", "r1", "r2") if tmr else ("r0",)
    for base, width in TMR_PC_REGS:
        expand_regs(rows, cpu, "cpu", [(f"{base}_{r}", width) for r in reps], "tmr_pc")
    for base, width in TMR_CTRL_REGS:
        expand_regs(rows, cpu, "cpu", [(f"{base}_{r}", width) for r in reps], "tmr_ctrl")

    # 2. Banco de registros cpuregs[1..31] (x0 cableado a 0 se excluye igual que en HARV)
    reg_w = 39 if ecc else 32
    for r_idx in range(1, 32):
        for bit in range(reg_w):
            rows.append((f"{cpu}/cpuregs[{r_idx}][{bit}]", f"cpu.cpuregs[{r_idx}]", bit, "cpuregs", 0))

    # 3. FFs sin proteger de la CPU
    expand_regs(rows, cpu, "cpu", CPU_DATAPATH_REGS, "cpu_datapath")
    expand_regs(rows, cpu, "cpu", CPU_MEM_IF_REGS, "cpu_mem_if")
    expand_regs(rows, cpu, "cpu", CPU_TRAP_REGS, "cpu_trap")
    expand_regs(rows, cpu, "cpu", CPU_COUNTERS_REGS, "cpu_counters")
    expand_regs(rows, cpu, "cpu", [(n, 1) for n in CPU_DECODER_1BIT], "cpu_decoder")

    # 4. Contadores de telemetría TMR/ECC de la CPU (solo si su módulo está habilitado)
    if tmr:
        expand_regs(rows, cpu, "cpu", [("count_tmr_pc", 32), ("count_tmr_ctrl", 32)], "cpu_telem", 1)
    if ecc:
        expand_regs(rows, cpu, "cpu", [("count_ecc_reg_sbu", 32), ("count_ecc_reg_dbu", 32)], "cpu_telem", 1)

    # 5. SoC, controladores bram_ecc, UART y uart_fatal_tx
    expand_regs(rows, root, "soc", SOC_BUS_REGS, "soc_bus")
    expand_regs(rows, root, "soc", SOC_TELEM_REGS, "soc_telem", 1)
    expand_regs(rows, f"{root}/imem", "imem", BRAM_IMEM_CTRL_REGS, "imem_ctrl")
    expand_regs(rows, f"{root}/dmem", "dmem", BRAM_DMEM_CTRL_REGS, "dmem_ctrl")
    expand_regs(rows, f"{root}/uart", "uart", UART_REGS, "uart")
    expand_regs(rows, f"{root}/u_fatal_tx", "u_fatal_tx", FATAL_TX_REGS, "uart_fatal_tx")
    return rows


def write_catalog(out_dir: Path, tmr: int, ecc: int, root: str):
    rows = build_targets(tmr, ecc, root)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"targets_tmr{tmr}_ecc{ecc}.tsv"
    with out_file.open("w", encoding="utf-8") as f:
        for idx, (path, reg_label, bit, domain, is_telem) in enumerate(rows):
            f.write(f"{idx}\t{path}\t{reg_label}\t{bit}\t{domain}\t{is_telem}\n")

    by_dom = {}
    telem_bits = 0
    for _, _, _, dom, is_t in rows:
        by_dom[dom] = by_dom.get(dom, 0) + 1
        telem_bits += is_t
    cpuregs_bits = by_dom.get("cpuregs", 0)
    ff_bits = len(rows) - cpuregs_bits
    print(f"[TMR={tmr}, ECC={ecc}] -> {out_file} | Total={len(rows)} bits "
          f"(FFs={ff_bits}, cpuregs={cpuregs_bits}, telemetria={telem_bits})")
    print("  Desglose:", ", ".join(f"{k}={v}" for k, v in by_dom.items()))


def main():
    ap = argparse.ArgumentParser(description="Genera catálogos de bits SEU para HPicoRV32")
    ap.add_argument("--out-dir", default="build/fi_targets")
    ap.add_argument("--root", default="/tb_fi_soc/uut")
    ap.add_argument("--tmr", type=int, choices=(0, 1))
    ap.add_argument("--ecc", type=int, choices=(0, 1))
    ap.add_argument("--all", action="store_true", help="Genera las 4 combinaciones TMR x ECC")
    args = ap.parse_args()

    out_dir = Path(args.out_dir)
    if args.all or (args.tmr is None and args.ecc is None):
        for tmr in (0, 1):
            for ecc in (0, 1):
                write_catalog(out_dir, tmr, ecc, args.root)
    else:
        write_catalog(out_dir, args.tmr or 0, args.ecc or 0, args.root)


if __name__ == "__main__":
    main()