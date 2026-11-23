#pragma once
#include <stdint.h>

#define REG_LEDS        (*(volatile uint32_t *)0x10000000)
#define REG_UART_CLKDIV (*(volatile uint32_t *)0x20000004)
#define REG_UART_DATA   (*(volatile uint32_t *)0x20000008)

#define CSR_TMR_PC_ERR   0xCC0
#define CSR_TMR_CTRL_ERR 0xCC1
#define CSR_ECC_REG_SBU  0xCC2
#define CSR_ECC_REG_DBU  0xCC3
#define CSR_TRAP_EPC     0xCC4
#define CSR_TRAP_CAUSE   0xCC5
#define REG_ECC_IMEM_SBU (*(volatile uint32_t *)0x30000000)
#define REG_ECC_IMEM_DBU (*(volatile uint32_t *)0x30000004)
#define REG_ECC_DMEM_SBU (*(volatile uint32_t *)0x30000008)
#define REG_ECC_DMEM_DBU (*(volatile uint32_t *)0x3000000C)

#define TRAP_CAUSE_NONE     0u
#define TRAP_CAUSE_ILLINSN  1u
#define TRAP_CAUSE_BREAK    2u
#define TRAP_CAUSE_MISALIGN 3u
#define TRAP_CAUSE_HARV_WX  4u
#define TRAP_CAUSE_DMEM_DBE 5u

#define _HPICO_READ_CSR(csr) ({             \
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
#define HPICO_READ_CSR(csr) _HPICO_READ_CSR(csr)

static inline uint32_t tmr_read_pc_err(void)   { return HPICO_READ_CSR(CSR_TMR_PC_ERR); }
static inline uint32_t tmr_read_ctrl_err(void) { return HPICO_READ_CSR(CSR_TMR_CTRL_ERR); }
static inline uint32_t ecc_read_reg_sbu(void)  { return HPICO_READ_CSR(CSR_ECC_REG_SBU); }
static inline uint32_t ecc_read_reg_dbu(void)  { return HPICO_READ_CSR(CSR_ECC_REG_DBU); }
static inline uint32_t trap_read_epc(void)     { return HPICO_READ_CSR(CSR_TRAP_EPC); }
static inline uint32_t trap_read_cause(void)   { return HPICO_READ_CSR(CSR_TRAP_CAUSE); }
static inline void     trap_halt(void)         { __asm__ volatile ("ebreak"); }

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
