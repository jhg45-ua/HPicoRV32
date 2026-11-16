#include "../../common/io.h"

#ifdef SIM_FAST
#define HEARTBEAT_DELAY 50
#else
#define HEARTBEAT_DELAY 250000
#endif

// Variables en DMEM para ejercitar .data, .bss, lw/sw y RMW (sb) con ECC
static volatile uint32_t dmem_cnt  = 0x12340000;
static volatile uint8_t  dmem_byte = 0;

void main(void) {
    // 100 MHz / 115200 baudios = 868
    REG_UART_CLKDIV = 868;
    dmem_cnt++;
    dmem_byte++;
    puts("\r\n");
    puts("==================================================\r\n");
    puts("  SHRV32 (PicoRV32) en Digilent Nexys A7-100T     \r\n");
    puts("==================================================\r\n");
    puts("CPU iniciada correctamente. Contador en LEDs...\r\n\r\n");

    uint32_t counter = 0;
    while (1) {
        REG_LEDS = counter & 0x7FFF;

        if ((counter & 0x0F) == 0) {
            puts("[SHRV32 Latido] Contador = ");
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
