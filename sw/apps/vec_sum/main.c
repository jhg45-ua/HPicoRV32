#include "../../common/io.h"

#define VEC_LEN 300u

// En simpleuart.v la condicion de desplazamiento es (send_divcnt > cfg_divider),
// por lo que cada bit dura exactamente (cfg_divider + 2) ciclos de reloj:
// - SIM_FAST: 14 + 2 = 16 ciclos/bit (potencia de 2 limpia para el receptor del TB)
// - Placa:    868 + 2 = 870 ciclos/bit (~115200 baudios @ 100 MHz)
#ifdef SIM_FAST
#define UART_DIV 14u
#define UART_FLUSH_DLY 64u
#else
#define UART_DIV 868u
#define UART_FLUSH_DLY 3000u
#endif

// 3 * 300 * 4 B = 3,600 B en .bss (cabe sobradamente en los 8 KB de DMEM).
// 'volatile' obliga a leer y escribir fisicamente en DMEM (impide que gcc -Os
// precalcule la suma en compilacion y deje el bucle vacio).
static volatile uint32_t vec_a[VEC_LEN];
static volatile uint32_t vec_b[VEC_LEN];
static volatile uint32_t vec_c[VEC_LEN];

static void init_vectors(void) {
    for (uint32_t i = 0; i < VEC_LEN; i++) {
        // Solo desplazamientos y sumas: RV32I no tiene instruccion MUL hardware
        vec_a[i] = (i << 2) + i + 0x00001001u; // 5*i + 0x1001
        vec_b[i] = (i << 3) - i + 0x00010007u;       // 7*i + 0x10007
    }
}

static uint32_t compute_and_hash(void) {
    // 1. Nucleo del benchmark HARV: C[i] = A[i] + B[i] sobre 300 elementos
    for (uint32_t i = 0; i < VEC_LEN; i++) {
        vec_c[i] = vec_a[i] + vec_b[i];
    }

    // 2. Firma sensible al orden y a cada bit (rotacion 5b + XOR) sobre todo C[]
    //    Aprovecha BARREL_SHIFTER=1 sin necesitar multiplicacion ni tablas CRC
    uint32_t hash = 0x12345678u;
    for (uint32_t i = 0; i < VEC_LEN; i++) {
        uint32_t v = vec_c[i];
        hash = ((hash << 5) | (hash >> 27)) ^ v;
    }
    return hash;
}

void main(void) {
    // Fin de warm-up: fija el divisor UART y senaliza inicio del calculo en LEDs
    REG_UART_CLKDIV = UART_DIV;
    REG_LEDS = 0x0001u;

    init_vectors();
    uint32_t res = compute_and_hash();

    // Oraculo funcional limpio por UART (SIN contadores TMR/ECC para no generar
    // falsos Mismatch cuando un fallo sea corregido con exito)
    puts("RES=");
    puthex(res);
    puts("\n");

    // Espera a que el ultimo byte ('\n') termine de salir del registro de
    // desplazamiento send_pattern de simpleuart antes de activar la marca de fin
    delay(UART_FLUSH_DLY);

    REG_LEDS = 0x7FFFu;
    while (1) {
        __asm__ volatile ("");
    }
}