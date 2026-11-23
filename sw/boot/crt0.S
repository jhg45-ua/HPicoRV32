.section .init, "ax"
.global _start
.global main
/* Declaramos trap_handler como símbolo débil (.weak): si tu programa en C define
 * su propia función void trap_handler(void), el enlazador usará la tuya; si no la
 * define (como en fi_bench), usará la etiqueta por defecto de más abajo. */
.weak   trap_handler

_start:
    /*En el reset la CPU siempre arranca en 0x0000_0000. Saltamos a _reset_init
     * y dejamos 3 instrucciones nop (4 * 4 = 16 bytes) para llegar justo a 0x0000_0010. */
    j    _reset_init        /* 0x0000_0000: Entrada tras Power-On Reset */
    nop                     /* 0x0000_0004: Relleno hasta PROGADDR_TRAP (0x10) */
    nop                     /* 0x0000_0008 */
    nop                     /* 0x0000_000C */

/* =============================================================================
 * Vector de Soft-Trap en 0x0000_0010 (PROGADDR_TRAP)
 * Cuando ocurre un fallo capturable, el hardware pone PC = 0x0000_0010.
 * Como hemos interrumpido main() en cualquier instrucción, antes de llamar a C
 * debemos guardar en la pila (DMEM) los 16 registros temporales ("caller-saved")
 * que una función C podría pisar (16 registros * 4 bytes = 64 bytes).
 * ============================================================================= */
.org 0x00000010
_trap_vector:
    /* 1. Prólogo: abrimos hueco de 64 bytes en la pila y guardamos contexto */
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

    /* 2. Saltamos a la rutina C de diagnóstico y gestión del trap */
    jal  ra, trap_handler

    /* 3. Epílogo (solo llega aquí si trap_handler hizo 'return' en lugar de trap_halt):
     *    recuperamos los 16 registros tal como estaban antes del fallo y cerramos la pila. */
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
    /* 4. Instrucción mret (codificada en binario 0x30200073): le dice al hardware que
     *    salimos del trap (trap_active = 0) y que continúe en la siguiente instrucción (EPC + 4). */
    .word 0x30200073

/* Manejador débil por defecto: si la aplicación no define trap_handler() en C,
 * ejecuta ebreak estando ya en trap_active=1, lo que detiene la CPU en Hard-Trap. */
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