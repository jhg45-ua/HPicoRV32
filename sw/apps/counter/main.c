#include "../../common/io.h"

#ifdef SIM_FAST
#define HEARTBEAT_DELAY 50
#else
#define HEARTBEAT_DELAY 250000
#endif

// Variables en DMEM para ejercitar .data, .bss, lw/sw y RMW (sb) con ECC
static volatile uint32_t dmem_cnt  = 0x12340000;
static volatile uint8_t  dmem_byte = 0;
static volatile uint32_t trap_handled_cnt = 0;

// Rutina de atención a excepciones (Soft-Trap Handler) invocada desde _trap_vector (0x0000_0010):
// 1. Consulta los nuevos CSRs de diagnóstico de excepción: CSR_TRAP_CAUSE (0xCC5) y CSR_TRAP_EPC (0xCC4).
// 2. Señaliza de inmediato el código de fallo en REG_LEDS (0x7000 | cause).
// 3. Consulta los CSRs internos TMR/ECC (0xCC0..0xCC3) y contadores MMIO de BRAM (0x3000_0000..0x3000_000C)
//    y emite el volcado de diagnóstico por UART.
// 4. Si la causa es TRAP_CAUSE_BREAK (ecall/ebreak de prueba), retorna vía mret a EPC + 4;
//    si es un fallo crítico (ILLINSN, MISALIGN, HARV_WX, DMEM_DBE), entra en parada segura (trap_halt).
void trap_handler(void) {
    uint32_t cause = trap_read_cause();
    uint32_t epc   = trap_read_epc();

    REG_LEDS = 0x7000u | (cause & 0x0Fu);
    trap_handled_cnt++;

    puts("[HPicoRV32 TRAP] CAUSE=");
    puthex(cause);
    puts(" EPC=");
    puthex(epc);
    puts(" | PC=");
    puthex(tmr_read_pc_err());
    puts(" CTRL=");
    puthex(tmr_read_ctrl_err());
    puts(" SBU=");
    puthex(ecc_read_reg_sbu());
    puts(" DBU=");
    puthex(ecc_read_reg_dbu());
    puts(" ISBU=");
    puthex(REG_ECC_IMEM_SBU);
    puts(" IDBU=");
    puthex(REG_ECC_IMEM_DBU);
    puts(" DSBU=");
    puthex(REG_ECC_DMEM_SBU);
    puts(" DDBU=");
    puthex(REG_ECC_DMEM_DBU);
    puts("\r\n");

    if (cause == TRAP_CAUSE_BREAK) {
        return; // Retorna a _trap_vector -> restaura registros y ejecuta mret (EPC + 4)
    }

    trap_halt(); // Ejecuta ebreak con trap_active=1 -> escala a Hard-Trap (cpu_state_trap)
}

void main(void) {
    // 100 MHz / 115200 baudios = 868
    REG_UART_CLKDIV = 868;
    dmem_cnt++;
    dmem_byte++;
    puts("\r\n");
    puts("==================================================\r\n");
    puts("  HPicoRV32 (Hardened PicoRV32) - Nexys A7-100T   \r\n");
    puts("==================================================\r\n");
    puts("CPU iniciada correctamente. Contador en LEDs...\r\n\r\n");

    uint32_t counter = 0;
    while (1) {
        REG_LEDS = counter & 0x7FFF;

        if ((counter & 0x0F) == 0) {
            puts("[HPicoRV32 Latido] Contador = ");
            char hex_char = "0123456789ABCDEF"[(counter >> 4) & 0x0F];
            putc(hex_char);
            puts(" | PC=");
            puthex(tmr_read_pc_err());
            puts(" CTRL=");
            puthex(tmr_read_ctrl_err());
            puts(" SBU=");
            puthex(ecc_read_reg_sbu());
            puts(" DBU=");
            puthex(ecc_read_reg_dbu());
            puts(" ISBU=");
            puthex(REG_ECC_IMEM_SBU);
            puts(" IDBU=");
            puthex(REG_ECC_IMEM_DBU);
            puts(" DSBU=");
            puthex(REG_ECC_DMEM_SBU);
            puts(" DDBU=");
            puthex(REG_ECC_DMEM_DBU);
            puts("\r\n");
        }

        dmem_cnt++;
        dmem_byte = (uint8_t)(counter & 0xFF);
        counter++;
        delay(HEARTBEAT_DELAY);
    }
}
