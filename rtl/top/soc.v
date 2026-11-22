// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       soc.v
// Descripción:  Wrapper de vuelo limpio del SoC Harvard (ENABLE_FI=0, 6 puertos físicos)
// Reloj/Reset:  clk (flanco subida, 100 MHz) | resetn (activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module soc #(
    parameter integer IMEM_WORDS     = 2048,                 // 8 KB: 0x0000_0000 - 0x0000_1FFF
    parameter integer DMEM_WORDS     = 2048,                 // 8 KB: 0x0000_2000 - 0x0000_3FFF
    parameter [0:0]   ENABLE_TMR     = 1'b1,                 // TMR 2-de-3 en PC y control de CPU
    parameter [0:0]   ENABLE_REG_ECC = 1'b1,                 // ECC Hsiao (39,32) en cpuregs
    parameter         FIRMWARE_FILE  = "build/firmware.hex"
) (
    input         clk,     // Reloj del sistema a 100 MHz (Nexys A7 pin E3)
    input         resetn,  // Botón externo de reset activo bajo (CPU_RESETN)
    output        trap,    // Trampa de CPU, violación Harvard W^X o DBE ECC -> LED15
    output [14:0] leds,    // 15 LEDs de usuario mapeados en 0x1000_0000
    output        ser_tx,  // Línea TX UART hacia el puente USB-UART FTDI
    input         ser_rx   // Línea RX UART desde el puente USB-UART FTDI
);

  // Envoltorio limpio de vuelo: fija ENABLE_FI=0 y ata el bus FI a 0 para que
  // síntesis pode el 100% de la lógica de inyección dejando solo los 6 pines físicos.
  soc_core #(
      .IMEM_WORDS    (IMEM_WORDS),
      .DMEM_WORDS    (DMEM_WORDS),
      .ENABLE_TMR    (ENABLE_TMR),
      .ENABLE_REG_ECC(ENABLE_REG_ECC),
      .FIRMWARE_FILE (FIRMWARE_FILE),
      .ENABLE_FI     (1'b0)
  ) u_core (
      .clk          (clk),
      .resetn       (resetn),
      .trap         (trap),
      .leds         (leds),
      .ser_tx       (ser_tx),
      .ser_rx       (ser_rx),
      .fi_valid_i   (1'b0),
      .fi_target_i  (4'd0),
      .fi_rep_mask_i(3'd0),
      .fi_bit_mask_i(39'd0),
      .fi_ack_o     ()
  );

endmodule
