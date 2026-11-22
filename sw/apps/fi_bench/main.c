// =============================================================================
// Benchmark bare-metal estilo HARV: Suma de vectores (300 elementos)
// Balizas en REG_LEDS para el testbench:
//   0x0001 = fin de crt0.S, empieza el cálculo
//   0x0002 = empieza la suma C[i] = A[i] + B[i] + pruebas RMW (sb/sh)
//   0x0003 = empieza la reducción final de rmw_bytes/rmw_halves
//   0x0004 = cómputo y telemetría terminados (empieza la impresión UART)
//   0x7FFF = UART vaciada, corrida completada con éxito
// =============================================================================
#include "../../common/io.h"

#define VEC_LEN 300

// En simulación (SIM_FAST=1) aceleramos UART a DIV=8 (10 ciclos/bit) para no perder
// milisegundos esperando al puerto serie; en FPGA (SIM_FAST=0) va a 115200 baudios (DIV=868).
#ifdef SIM_FAST
#define UART_DIV 8
#define FLUSH_DELAY 200
#else
#define UART_DIV 868
#define FLUSH_DELAY 15000
#endif

// Tabla constante en IMEM (.rodata): ejercita lecturas de solo lectura con ECC en IMEM
static const uint32_t k_weights[8] = {
    0x13579BDFu, 0x2468ACE0u, 0x0F1E2D3Cu, 0x4B5A6978u,
    0x87654321u, 0xA5A55A5Au, 0x3C6996C3u, 0xF0E1D2C3u
};

// Buffers en DMEM (.bss, 3600 B en total) y buffers pequeños en .data para probar sb/sh (RMW ECC)
static uint32_t vec_a[VEC_LEN];
static uint32_t vec_b[VEC_LEN];
static uint32_t vec_c[VEC_LEN];

static volatile uint8_t  rmw_bytes[8]  = {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88};
static volatile uint16_t rmw_halves[4] = {0x1234, 0x5678, 0x9ABC, 0xDEF0};

// Rotación circular a la izquierda de 32 bits (hace que el hash dependa del orden exacto)
static inline uint32_t rotl32(uint32_t x, uint32_t n) {
    return (x << n) | (x >> (32u - n));
}

static void print_telem_line(uint32_t pc_err, uint32_t ctrl_err,
                             uint32_t reg_sbu, uint32_t reg_dbu,
                             uint32_t imem_sbu, uint32_t imem_dbu,
                             uint32_t dmem_sbu, uint32_t dmem_dbu) {
    puts("TELEM PC=");
    puthex(pc_err);
    puts(" CTRL=");
    puthex(ctrl_err);
    puts(" SBU=");
    puthex(reg_sbu);
    puts(" DBU=");
    puthex(reg_dbu);
    puts(" ISBU=");
    puthex(imem_sbu);
    puts(" IDBU=");
    puthex(imem_dbu);
    puts(" DSBU=");
    puthex(dmem_sbu);
    puts(" DDBU=");
    puthex(dmem_dbu);
    puts("\r\n");
}

__attribute__((used, noinline, noreturn)) static void bench_main(void) {
    REG_UART_CLKDIV = UART_DIV;
    REG_LEDS        = 0x0001;

    // Inicializacion determinista en DMEM (A, B) con desplazamientos constantes (sin __mulsi3 ni shifts variables)
    for (uint32_t i = 0; i < VEC_LEN; i++) {
        uint32_t w   = k_weights[i & 7u];
        uint32_t mix = i ^ (i << 8) ^ (i << 16) ^ (i << 24);
        vec_a[i] = w ^ mix;
        vec_b[i] = rotl32(w, 7u) + ((i << 16) | (i << 2) | 3u);
    }

    REG_LEDS = 0x0002;

    // Kernel principal estilo HARV: Suma C[i] = A[i] + B[i], RMW (sb/sh) y lectura/reduccion de C[i]
    volatile uint32_t *va = vec_a;
    volatile uint32_t *vb = vec_b;
    volatile uint32_t *vc = vec_c;
    uint32_t result = 0x811C9DC5u;

    for (uint32_t i = 0; i < VEC_LEN; i++) {
        uint32_t sum  = va[i] + vb[i];
        uint32_t salt = i ^ (i << 11) ^ (i << 21) ^ 0x9E3779B9u;
        vc[i] = sum;
        result = rotl32(result, 5u) ^ (vc[i] + salt);

        // Ejercita escrituras sub-palabra RMW (sb y sh) bajo proteccion ECC en DMEM
        if ((i & 7u) == 0u) {
            uint32_t bi = (i >> 3) & 7u;
            uint32_t hi = (i >> 3) & 3u;
            rmw_bytes[bi]  = (uint8_t)(rmw_bytes[bi] ^ (uint8_t)(sum ^ (sum >> 8)) ^ (uint8_t)i);
            rmw_halves[hi] = (uint16_t)(rmw_halves[hi] + (uint16_t)(sum ^ (sum >> 16)));
        }
    }

    REG_LEDS = 0x0003;

    for (uint32_t i = 0; i < 8u; i++) {
        result = rotl32(result, 3u) ^ (uint32_t)rmw_bytes[i];
    }
    for (uint32_t i = 0; i < 4u; i++) {
        result = rotl32(result, 7u) ^ (uint32_t)rmw_halves[i];
    }

    // Leemos los 8 contadores hardware ANTES de imprimir para no mezclar fallos de impresión UART
    // con la ventana de cómputo (0xCC0..0xCC3 en CPU + 0x3000_0000..0C en IMEM/DMEM).
    uint32_t pc_err   = tmr_read_pc_err();
    uint32_t ctrl_err = tmr_read_ctrl_err();
    uint32_t reg_sbu  = ecc_read_reg_sbu();
    uint32_t reg_dbu  = ecc_read_reg_dbu();
    uint32_t imem_sbu = REG_ECC_IMEM_SBU;
    uint32_t imem_dbu = REG_ECC_IMEM_DBU;
    uint32_t dmem_sbu = REG_ECC_DMEM_SBU;
    uint32_t dmem_dbu = REG_ECC_DMEM_DBU;

    // Baliza 4: el testbench apaga aquí el inyector autónomo
    REG_LEDS = 0x0004;

    // Emitimos RESULT primero y TELEM aparte para que los contadores no alteren el hash matemático
    puts("RESULT=0x");
    puthex(result);
    puts("\r\n");

    print_telem_line(pc_err, ctrl_err, reg_sbu, reg_dbu,
                     imem_sbu, imem_dbu, dmem_sbu, dmem_dbu);

    // Espera a que el transmisor simpleuart termine de sacar el último '\n' antes de señalar 0x7FFF
    delay(FLUSH_DELAY);
    REG_LEDS = 0x7FFF;

    // Bucle infinito: si main() retornara caería en ebreak de crt0.S levantando trap=1
    for (;;) {
        __asm__ volatile ("nop");
    }
}

// Truco de entrada "naked" (sin prólogo del compilador):
// El reset hardware NO borra la memoria RAM32M de cpuregs. Un main() normal guardaría s0..s8 en la
// pila al arrancar, leyendo residuos de la corrida anterior (y disparando falsos SBE latentes).
// Aquí ponemos a 0 x1 y x5..x31 a mano (respetando sp/gp/tp en x2..x4) y saltamos a bench_main.
__attribute__((naked, noreturn)) void main(void) {
    __asm__ volatile (
        "li x1, 0\n"
        "li x5, 0\n"  "li x6, 0\n"  "li x7, 0\n"
        "li x8, 0\n"  "li x9, 0\n"  "li x10, 0\n" "li x11, 0\n"
        "li x12, 0\n" "li x13, 0\n" "li x14, 0\n" "li x15, 0\n"
        "li x16, 0\n" "li x17, 0\n" "li x18, 0\n" "li x19, 0\n"
        "li x20, 0\n" "li x21, 0\n" "li x22, 0\n" "li x23, 0\n"
        "li x24, 0\n" "li x25, 0\n" "li x26, 0\n" "li x27, 0\n"
        "li x28, 0\n" "li x29, 0\n" "li x30, 0\n" "li x31, 0\n"
        "j bench_main\n"
    );
}
