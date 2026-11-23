.section .init, "ax"
.global _start
.global main
.weak   trap_handler

_start:
    j    _reset_init        /* 0x0000_0000: Entrada tras Power-On Reset */
    nop                     /* 0x0000_0004: Relleno hasta PROGADDR_TRAP (0x10) */
    nop                     /* 0x0000_0008 */
    nop                     /* 0x0000_000C */

/* =============================================================================
 * Vector de Soft-Trap en 0x0000_0010 (PROGADDR_TRAP)
 * - Salva los 16 registros caller-saved de la ABI RISC-V (64 bytes en DMEM)
 * - Invoca trap_handler() en C
 * - Si trap_handler() retorna, restaura contexto y ejecuta mret (EPC + 4)
 * ============================================================================= */
.org 0x00000010
_trap_vector:
    addi sp, sp, -64
    sw   ra,  0(sp)
    sw   t0,  4(sp)
    sw   t1,  8(sp)
    sw   t2, 12(sp)
    sw   a0, 16(sp)
    sw   a1, 20(sp)
    sw   a2, 24(sp)
    sw   a3, 28(sp)
    sw   a4, 32(sp)
    sw   a5, 36(sp)
    sw   a6, 40(sp)
    sw   a7, 44(sp)
    sw   t3, 48(sp)
    sw   t4, 52(sp)
    sw   t5, 56(sp)
    sw   t6, 60(sp)

    jal  ra, trap_handler

    lw   ra,  0(sp)
    lw   t0,  4(sp)
    lw   t1,  8(sp)
    lw   t2, 12(sp)
    lw   a0, 16(sp)
    lw   a1, 20(sp)
    lw   a2, 24(sp)
    lw   a3, 28(sp)
    lw   a4, 32(sp)
    lw   a5, 36(sp)
    lw   a6, 40(sp)
    lw   a7, 44(sp)
    lw   t3, 48(sp)
    lw   t4, 52(sp)
    lw   t5, 56(sp)
    lw   t6, 60(sp)
    addi sp, sp, 64
    .word 0x30200073        /* mret: limpia trap_active y salta a EPC + 4 */

/* Manejador débil por defecto: escala a Hard-Trap si la app no define trap_handler */
trap_handler:
    ebreak
1:  j    1b

_reset_init:
    /* Puntero de pila al final de DMEM (0x0000_4000) */
    la   sp, _estack

    /* Copiar variables globales inicializadas (.data) de IMEM -> DMEM */
    la   t0, _etext
    la   t1, _sdata
    la   t2, _edata
1:  bgeu t1, t2, 2f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    1b
2:
    /* Poner a cero variables globales sin inicializar (.bss) en DMEM */
    la   t1, _sbss
    la   t2, _ebss
3:  bgeu t1, t2, 4f
    sw   zero, 0(t1)
    addi t1, t1, 4
    j    3b
4:
    /* Saltar a main y bucle seguro si retorna */
    jal  ra, main
5:  j    5b