#pragma once
#include <stdint.h>

#define REG_LEDS        (*(volatile uint32_t *)0x10000000)
#define REG_UART_CLKDIV (*(volatile uint32_t *)0x20000004)
#define REG_UART_DATA   (*(volatile uint32_t *)0x20000008)

#define CSR_TMR_PC_ERR   0xCC0
#define CSR_TMR_CTRL_ERR 0xCC1
#define CSR_ECC_REG_SBU  0xCC2
#define CSR_ECC_REG_DBU  0xCC3
#define REG_ECC_IMEM_SBU (*(volatile uint32_t *)0x30000000)
#define REG_ECC_IMEM_DBU (*(volatile uint32_t *)0x30000004)
#define REG_ECC_DMEM_SBU (*(volatile uint32_t *)0x30000008)
#define REG_ECC_DMEM_DBU (*(volatile uint32_t *)0x3000000C)

#define _SHRV_READ_CSR(csr) ({              \
    uint32_t _val;                          \
    __asm__ volatile (                      \
        ".option push\n\t"                  \
        ".option arch, +zicsr\n\t"          \
        "csrr %0, " #csr "\n\t"             \
        ".option pop"                       \
        : "=r"(_val)                        \
    );                                      \
    _val;                                   \
})
#define SHRV_READ_CSR(csr) _SHRV_READ_CSR(csr)

static inline uint32_t tmr_read_pc_err(void)   { return SHRV_READ_CSR(CSR_TMR_PC_ERR); }
static inline uint32_t tmr_read_ctrl_err(void) { return SHRV_READ_CSR(CSR_TMR_CTRL_ERR); }
static inline uint32_t ecc_read_reg_sbu(void)  { return SHRV_READ_CSR(CSR_ECC_REG_SBU); }
static inline uint32_t ecc_read_reg_dbu(void)  { return SHRV_READ_CSR(CSR_ECC_REG_DBU); }

static inline void putc(char c) {
    if (c == '\n') REG_UART_DATA = '\r';
    REG_UART_DATA = c;
}

static inline void puts(const char *s) {
    while (*s) putc(*s++);
}

static inline void puthex(uint32_t val) {
    for (int shift = 28; shift >= 0; shift -= 4) {
        putc("0123456789ABCDEF"[(val >> shift) & 0xF]);
    }
}

static inline void delay(volatile uint32_t count) {
    while (count--) __asm__ volatile("");
}

static inline uint8_t uart_getc(void) {
    int32_t c;
    while ((c = (int32_t)REG_UART_DATA) == -1);
    return (uint8_t)c;
}
