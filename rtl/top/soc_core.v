// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       soc_core.v
// Descripción:  Núcleo del SoC Harvard endurecido con bus de inyección FI opcional
// Reloj/Reset:  clk (flanco subida, 100 MHz) | resetn (activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module soc_core #(
    parameter integer IMEM_WORDS     = 2048,                 // 8 KB: 0x0000_0000 - 0x0000_1FFF
    parameter integer DMEM_WORDS     = 2048,                 // 8 KB: 0x0000_2000 - 0x0000_3FFF
    parameter [0:0]   ENABLE_TMR     = 1'b1,                 // TMR 2-de-3 en PC y control de CPU
    parameter [0:0]   ENABLE_REG_ECC = 1'b1,                 // ECC Hsiao (39,32) en cpuregs
    parameter         FIRMWARE_FILE  = "build/firmware.hex",
    parameter [0:0]   ENABLE_FI      = 1'b0                  // Hooks de inyección (0 en vuelo)
) (
    input             clk,           // Reloj del sistema a 100 MHz (Nexys A7 pin E3)
    input             resetn,        // Botón externo de reset activo bajo (CPU_RESETN)
    output            trap,          // Trampa de CPU, violación Harvard W^X o DBE ECC -> LED15
    output reg [14:0] leds,          // 15 LEDs de usuario mapeados en 0x1000_0000
    output            ser_tx,        // Línea TX UART hacia el puente USB-UART FTDI
    input             ser_rx,        // Línea RX UART desde el puente USB-UART FTDI
    // Bus desacoplado de inyección de fallos (optimizado a 0 si ENABLE_FI=0)
    input             fi_valid_i,    // Solicitud armada desde fault_injector
    input      [ 3:0] fi_target_i,   // Objetivo 0..7
    input      [ 2:0] fi_rep_mask_i, // Réplicas TMR (targets 0..4)
    input      [38:0] fi_bit_mask_i, // Máscara XOR de inversión
    output            fi_ack_o       // Pulso combinacional de consumo
);

  // Power-On Reset (POR): mantiene sys_resetn bajo durante 63 ciclos tras soltar resetn
  reg [5:0] reset_cnt = 6'd0;
  wire sys_resetn = &reset_cnt;

  always @(posedge clk) begin
    if (!resetn) reset_cnt <= 6'd0;
    else if (!sys_resetn) reset_cnt <= reset_cnt + 6'd1;
  end

  // Interfaz nativa de memoria de PicoRV32 (protocolo valid/ready, sin AXI)
  wire        mem_valid;
  wire        mem_instr;
  wire        mem_ready;
  wire [31:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [ 3:0] mem_wstrb;
  wire [31:0] mem_rdata;

  // Función constante Verilog-2001 para derivar el ancho de dirección desde WORDS
  function integer clog2;
    input integer value;
    integer v;
    begin
      v = value - 1;
      for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
    end
  endfunction

  localparam integer IMEM_ADDR_BITS = (IMEM_WORDS > 1) ? clog2(IMEM_WORDS) : 1;
  localparam integer DMEM_ADDR_BITS = (DMEM_WORDS > 1) ? clog2(DMEM_WORDS) : 1;

  // Límites de direcciones en bytes para partición Harvard (IMEM seguida de DMEM)
  localparam [31:0] IMEM_BYTES = IMEM_WORDS * 4;
  localparam [31:0] DMEM_BASE = IMEM_BYTES;
  localparam [31:0] DMEM_END = IMEM_BYTES + (DMEM_WORDS * 4);

  // Decodificador combinacional Harvard:
  // - IMEM: fetch de instrucciones (mem_instr=1) o lectura de constantes .rodata (wstrb=0)
  // - DMEM: solo accesos de datos (mem_instr=0), lectura o escritura
  wire imem_range = (mem_addr < IMEM_BYTES);
  wire dmem_range = (mem_addr >= DMEM_BASE) && (mem_addr < DMEM_END);

  wire imem_sel = mem_valid && imem_range && !(|mem_wstrb);
  wire dmem_sel = mem_valid && dmem_range && !mem_instr;
  // Detecta escritura sobre IMEM o ejecución desde DMEM (política W^X)
  wire harv_err = mem_valid && ((imem_range && (|mem_wstrb)) || (dmem_range && mem_instr));
  wire leds_sel = mem_valid && (mem_addr == 32'h1000_0000);
  wire uart_div_sel = mem_valid && (mem_addr == 32'h2000_0004);
  wire uart_dat_sel = mem_valid && (mem_addr == 32'h2000_0008);
  wire ecc_stat_sel = mem_valid && (mem_addr[31:4] == 28'h3000_000) && (mem_addr[1:0] == 2'b00);

  // Habilidad global de inyección (nunca en POR ni con el SoC en estado trap)
  wire fi_en_eff = ENABLE_FI && fi_valid_i && sys_resetn && !trap;
  wire cpu_fi_ack;
  wire imem_fi_ack;
  wire dmem_fi_ack;

  assign fi_ack_o = ENABLE_FI ? (cpu_fi_ack | imem_fi_ack | dmem_fi_ack) : 1'b0;

  // Núcleo HPicoRV32 (RV32I) con TMR selectivo (PC/control) y ECC en cpuregs
  wire cpu_trap;

  picorv32 #(
      .ENABLE_COUNTERS     (1),
      .ENABLE_COUNTERS64   (0),
      .ENABLE_REGS_16_31   (1),
      .ENABLE_REGS_DUALPORT(1),
      .TWO_STAGE_SHIFT     (1),
      .BARREL_SHIFTER      (1),
      .COMPRESSED_ISA      (0),
      .CATCH_MISALIGN      (1),
      .CATCH_ILLINSN       (1),
      .REGS_INIT_ZERO      (1),
      .ENABLE_TMR          (ENABLE_TMR),
      .ENABLE_ECC          (ENABLE_REG_ECC),
      .ENABLE_FI           (ENABLE_FI)
  ) cpu (
      .clk          (clk),
      .resetn       (sys_resetn),
      .trap         (cpu_trap),
      .mem_valid    (mem_valid),
      .mem_instr    (mem_instr),
      .mem_ready    (mem_ready),
      .mem_addr     (mem_addr),
      .mem_wdata    (mem_wdata),
      .mem_wstrb    (mem_wstrb),
      .mem_rdata    (mem_rdata),
      .mem_la_read  (),
      .mem_la_write (),
      .mem_la_addr  (),
      .mem_la_wdata (),
      .mem_la_wstrb (),
      .pcpi_valid   (),
      .pcpi_insn    (),
      .pcpi_rs1     (),
      .pcpi_rs2     (),
      .pcpi_wr      (1'b0),
      .pcpi_rd      (32'h0),
      .pcpi_wait    (1'b0),
      .pcpi_ready   (1'b0),
      .irq          (32'h0),
      .eoi          (),
      .trace_valid  (),
      .trace_data   (),
      .fi_valid_i   (fi_en_eff),
      .fi_target_i  (fi_target_i),
      .fi_rep_mask_i(fi_rep_mask_i),
      .fi_bit_mask_i(fi_bit_mask_i),
      .fi_ack_o     (cpu_fi_ack)
  );

  wire [IMEM_ADDR_BITS-1:0] imem_word_addr = mem_addr[IMEM_ADDR_BITS+1:2];
  wire [31:0]               dmem_byte_off  = mem_addr - DMEM_BASE;
  wire [DMEM_ADDR_BITS-1:0] dmem_word_addr = dmem_byte_off[DMEM_ADDR_BITS+1:2];

  // IMEM: 8 KB con Hsiao SEC-DED (READ_ONLY=1 desde bus, pero con auto-scrubbing interno)
  wire [31:0] imem_rdata;
  wire        imem_ready;
  wire        imem_sbe;
  wire        imem_dbe;

  bram_ecc #(
      .WORDS    (IMEM_WORDS),
      .ADDR_BITS(IMEM_ADDR_BITS),
      .READ_ONLY(1'b1),
      .USE_INIT (1'b1),
      .INIT_FILE(FIRMWARE_FILE),
      .ENABLE_FI(ENABLE_FI)
  ) imem (
      .clk       (clk),
      .resetn    (sys_resetn),
      .valid_i   (imem_sel),
      .wstrb_i   (4'b0000),
      .addr_i    (imem_word_addr),
      .wdata_i   (32'h0),
      .rdata_o   (imem_rdata),
      .ready_o   (imem_ready),
      .sbe_o     (imem_sbe),
      .dbe_o     (imem_dbe),
      .fi_valid_i(fi_en_eff && (fi_target_i == 4'd6)),
      .fi_mask_i (fi_bit_mask_i),
      .fi_ack_o  (imem_fi_ack)
  );

  // DMEM: 8 KB con Hsiao SEC-DED + RMW para sb/sh y auto-scrubbing
  wire [31:0] dmem_rdata;
  wire        dmem_ready;
  wire        dmem_sbe;
  wire        dmem_dbe;
  reg         harv_fault_r;  // Registro enclavado (sticky FF) de violación W^X
  reg         ecc_fault_r;   // Registro enclavado (sticky FF) de DBE incorregible en IMEM o DMEM

  bram_ecc #(
      .WORDS    (DMEM_WORDS),
      .ADDR_BITS(DMEM_ADDR_BITS),
      .READ_ONLY(1'b0),
      .USE_INIT (1'b0),
      .ENABLE_FI(ENABLE_FI)
  ) dmem (
      .clk       (clk),
      .resetn    (sys_resetn),
      .valid_i   (dmem_sel),
      .wstrb_i   ((harv_fault_r || ecc_fault_r) ? 4'b0000 : mem_wstrb),
      .addr_i    (dmem_word_addr),
      .wdata_i   (mem_wdata),
      .rdata_o   (dmem_rdata),
      .ready_o   (dmem_ready),
      .sbe_o     (dmem_sbe),
      .dbe_o     (dmem_dbe),
      .fi_valid_i(fi_en_eff && (fi_target_i == 4'd7)),
      .fi_mask_i (fi_bit_mask_i),
      .fi_ack_o  (dmem_fi_ack)
  );

  // Controlador UART (divisor a 115200 baudios configurado por firmware)
  wire [31:0] uart_div_do;
  wire [31:0] uart_dat_do;
  wire        uart_dat_wait;

  simpleuart uart (
      .clk         (clk),
      .resetn      (sys_resetn),
      .ser_tx      (ser_tx),
      .ser_rx      (ser_rx),
      // Cualifica los strobes con !mem_ready para que los pulsos de control duren exactamente 1 ciclo
      .reg_div_we  ((uart_div_sel && !mem_ready) ? mem_wstrb : 4'b0000),
      .reg_div_di  (mem_wdata),
      .reg_div_do  (uart_div_do),
      .reg_dat_we  (uart_dat_sel && mem_wstrb[0] && !mem_ready),
      .reg_dat_re  (uart_dat_sel && !(|mem_wstrb) && !mem_ready),
      .reg_dat_di  (mem_wdata),
      .reg_dat_do  (uart_dat_do),
      .reg_dat_wait(uart_dat_wait)
  );

  // Telemetría ECC de memorias (acceso MMIO R/O en 0x3000_0000..0x3000_000C)
  reg [31:0] count_ecc_imem_sbu;
  reg [31:0] count_ecc_imem_dbu;
  reg [31:0] count_ecc_dmem_sbu;
  reg [31:0] count_ecc_dmem_dbu;

  reg        bus_ready_r;  // Pulso ready de 1 ciclo para periféricos MMIO y harv_err
  reg [31:0] mmio_rdata;

  // LED15 se enciende ante trampa de CPU, violación Harvard o DBE en memoria
  assign trap = cpu_trap | harv_fault_r | ecc_fault_r;

  // Sin lazo combinacional: mem_ready solo combina 3 flip-flops (uno activo a la vez)
  assign mem_ready = imem_ready || dmem_ready || bus_ready_r;

  assign mem_rdata = imem_ready ? imem_rdata : dmem_ready ? dmem_rdata : mmio_rdata;

  always @(posedge clk) begin
    if (!sys_resetn) begin
      bus_ready_r        <= 1'b0;
      harv_fault_r       <= 1'b0;
      ecc_fault_r        <= 1'b0;
      mmio_rdata         <= 32'h0;
      leds               <= 15'h0;
      count_ecc_imem_sbu <= 32'h0;
      count_ecc_imem_dbu <= 32'h0;
      count_ecc_dmem_sbu <= 32'h0;
      count_ecc_dmem_dbu <= 32'h0;
    end else begin
      bus_ready_r <= 1'b0;

      if (imem_sbe) count_ecc_imem_sbu <= count_ecc_imem_sbu + 32'd1;
      if (imem_dbe) count_ecc_imem_dbu <= count_ecc_imem_dbu + 32'd1;
      if (dmem_sbe) count_ecc_dmem_sbu <= count_ecc_dmem_sbu + 32'd1;
      if (dmem_dbe) count_ecc_dmem_dbu <= count_ecc_dmem_dbu + 32'd1;
      if (imem_dbe || dmem_dbe) ecc_fault_r <= 1'b1;

      if (mem_valid && !mem_ready) begin
        if (harv_err) begin
          harv_fault_r <= 1'b1;
          bus_ready_r  <= 1'b1;
        end else if (leds_sel) begin
          if ((|mem_wstrb) && !harv_fault_r && !ecc_fault_r) leds <= mem_wdata[14:0];
          mmio_rdata  <= {17'b0, leds};
          bus_ready_r <= 1'b1;
        end else if (uart_div_sel) begin
          mmio_rdata  <= uart_div_do;
          bus_ready_r <= 1'b1;
        end else if (uart_dat_sel) begin
          if (!uart_dat_wait) begin
            mmio_rdata  <= uart_dat_do;
            bus_ready_r <= 1'b1;
          end
        end else if (ecc_stat_sel) begin
          case (mem_addr[3:2])
            2'b00: mmio_rdata <= count_ecc_imem_sbu;
            2'b01: mmio_rdata <= count_ecc_imem_dbu;
            2'b10: mmio_rdata <= count_ecc_dmem_sbu;
            2'b11: mmio_rdata <= count_ecc_dmem_dbu;
          endcase
          bus_ready_r <= 1'b1;
        end
      end
    end
  end

endmodule
