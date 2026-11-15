.section .init
.global main

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