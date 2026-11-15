// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       soc.v
// Descripción:  Módulo raíz del SoC Harvard (PicoRV32 TMR + IMEM 8 KB + DMEM 8 KB + UART + LEDs)
// Reloj/Reset:  clk (flanco subida, 100 MHz) | resetn (activo bajo)
// =============================================================================

module soc #(
    parameter integer IMEM_WORDS    = 2048,                 // 8 KB: 0x0000_0000 - 0x0000_1FFF
    parameter integer DMEM_WORDS    = 2048,                 // 8 KB: 0x0000_2000 - 0x0000_3FFF
    parameter         FIRMWARE_FILE = "build/firmware.hex"
) (
    input             clk,     // Reloj del sistema a 100 MHz (Nexys A7 pin E3)
    input             resetn,  // Botón externo de reset activo bajo (CPU_RESETN)
    output            trap,    // Trampa de CPU o violación de acceso Harvard -> LED15
    output reg [14:0] leds,    // 15 LEDs de usuario mapeados en 0x1000_0000
    output            ser_tx,  // Línea TX UART hacia el puente USB-UART FTDI
    input             ser_rx   // Línea RX UART desde el puente USB-UART FTDI
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
  reg         mem_ready;
  wire [31:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [ 3:0] mem_wstrb;
  wire [31:0] mem_rdata;

  // Límites de direcciones en bytes para partición Harvard (IMEM seguida de DMEM)
  localparam [31:0] IMEM_BYTES = IMEM_WORDS * 4;
  localparam [31:0] DMEM_BASE  = IMEM_BYTES;
  localparam [31:0] DMEM_END   = IMEM_BYTES + (DMEM_WORDS * 4);

  // Decodificador combinacional Harvard:
  // - IMEM: fetch de instrucciones (mem_instr=1) o lectura de constantes .rodata (wstrb=0)
  // - DMEM: solo accesos de datos (mem_instr=0), lectura o escritura
  wire imem_range = (mem_addr < IMEM_BYTES);
  wire dmem_range = (mem_addr >= DMEM_BASE) && (mem_addr < DMEM_END);

  wire imem_sel     = mem_valid && imem_range && !(|mem_wstrb);
  wire dmem_sel     = mem_valid && dmem_range && !mem_instr;
  // Detecta escritura sobre IMEM o ejecución desde DMEM (política W^X)
  wire harv_err     = mem_valid && ((imem_range && (|mem_wstrb)) || (dmem_range && mem_instr));
  wire leds_sel     = mem_valid && (mem_addr == 32'h1000_0000);
  wire uart_div_sel = mem_valid && (mem_addr == 32'h2000_0004);
  wire uart_dat_sel = mem_valid && (mem_addr == 32'h2000_0008);

  // Núcleo PicoRV32 RV32I con endurecimiento TMR selectivo en PC y control
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
      .ENABLE_TMR          (1)
  ) cpu (
      .clk         (clk),
      .resetn      (sys_resetn),
      .trap        (cpu_trap),
      .mem_valid   (mem_valid),
      .mem_instr   (mem_instr),
      .mem_ready   (mem_ready),
      .mem_addr    (mem_addr),
      .mem_wdata   (mem_wdata),
      .mem_wstrb   (mem_wstrb),
      .mem_rdata   (mem_rdata),
      .mem_la_read (),
      .mem_la_write(),
      .mem_la_addr (),
      .mem_la_wdata(),
      .mem_la_wstrb(),
      .pcpi_valid  (),
      .pcpi_insn   (),
      .pcpi_rs1    (),
      .pcpi_rs2    (),
      .pcpi_wr     (1'b0),
      .pcpi_rd     (32'h0),
      .pcpi_wait   (1'b0),
      .pcpi_ready  (1'b0),
      .irq         (32'h0),
      .eoi         ()
  );

  // IMEM: 8 KB (instrucciones + .rodata), solo lectura desde el bus de la CPU
  wire [31:0] imem_rdata;

  bram_sp #(
      .WORDS    (IMEM_WORDS),
      .ADDR_BITS(11),
      .USE_INIT (1'b1),
      .INIT_FILE(FIRMWARE_FILE)
  ) imem (
      .clk  (clk),
      .en   (imem_sel && !mem_ready),
      .wstrb(4'b0000),
      .addr (mem_addr[12:2]),
      .wdata(32'h0),
      .rdata(imem_rdata)
  );

  // DMEM: 8 KB (variables + pila), lectura/escritura sin precarga
  wire [31:0] dmem_rdata;

  bram_sp #(
      .WORDS    (DMEM_WORDS),
      .ADDR_BITS(11),
      .USE_INIT (1'b0)
  ) dmem (
      .clk  (clk),
      .en   (dmem_sel && !mem_ready),
      .wstrb(mem_wstrb),
      .addr (mem_addr[12:2]),
      .wdata(mem_wdata),
      .rdata(dmem_rdata)
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

  // Controlador síncrono de respuesta del bus y multiplexor de lectura
  reg        imem_read_r;   // 1 en el ciclo tras aceptar lectura de IMEM
  reg        dmem_read_r;   // 1 en el ciclo tras aceptar lectura de DMEM
  reg        harv_fault_r;  // Latch de violación W^X (se mantiene hasta reset)
  reg [31:0] mmio_rdata;

  // LED15 se enciende ante trampa interna de CPU o violación Harvard
  assign trap = cpu_trap | harv_fault_r;

  // Mux combinacional: entrega la salida registrada de la BRAM correspondiente o MMIO
  assign mem_rdata = imem_read_r ? imem_rdata :
                     dmem_read_r ? dmem_rdata : mmio_rdata;

  always @(posedge clk) begin
    if (!sys_resetn) begin
      mem_ready    <= 1'b0;
      imem_read_r  <= 1'b0;
      dmem_read_r  <= 1'b0;
      harv_fault_r <= 1'b0;
      mmio_rdata   <= 32'h0;
      leds         <= 15'h0;
    end else begin
      // Por defecto desactivados: mem_ready e *_read_r son pulsos de 1 ciclo
      mem_ready   <= 1'b0;
      imem_read_r <= 1'b0;
      dmem_read_r <= 1'b0;

      if (mem_valid && !mem_ready) begin
        if (imem_sel) begin
          // IMEM captura addr en este flanco; el dato queda válido en el ciclo siguiente
          imem_read_r <= 1'b1;
          mem_ready   <= 1'b1;
        end else if (dmem_sel) begin
          // DMEM captura addr/wdata en este flanco; solo activa dmem_read_r si es lectura
          dmem_read_r <= !(|mem_wstrb);
          mem_ready   <= 1'b1;
        end else if (harv_err) begin
          // Cierra el ciclo de bus para no bloquear la CPU y dispara trap (LED15)
          harv_fault_r <= 1'b1;
          mem_ready    <= 1'b1;
        end else if (leds_sel) begin
          if (|mem_wstrb) leds <= mem_wdata[14:0];
          mmio_rdata <= {17'b0, leds};
          mem_ready  <= 1'b1;
        end else if (uart_div_sel) begin
          mmio_rdata <= uart_div_do;
          mem_ready  <= 1'b1;
        end else if (uart_dat_sel) begin
          // Mantiene en espera a la CPU hasta que termine el envío TX UART anterior
          if (!uart_dat_wait) begin
            mmio_rdata <= uart_dat_do;
            mem_ready  <= 1'b1;
          end
        end
      end
    end
  end

endmodule
