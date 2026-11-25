// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       tb_fi_soc.v
// Descripción:  Socket de simulación limpio para campañas externas de inyección
//               de fallos (Questa TCL / XSim / Icarus / Verilator), sin hooks FI.
// Reloj/Reset:  clk (100 MHz, período 10 ns) | resetn (activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module tb_fi_soc #(
    parameter [0:0] ENABLE_TMR = 1'b1,
    parameter [0:0] ENABLE_REG_ECC = 1'b1,
    parameter FIRMWARE_FILE = "build/firmware.hex",
    parameter integer UART_BIT_CYCLES = 16  // SIM_FAST: UART_DIV(14) + 2 = 16
);

  reg clk = 1'b0;
  always #5 clk = ~clk;  // 100 MHz

  reg         resetn = 1'b0;
  wire        trap;
  wire [14:0] leds;
  wire        ser_tx;
  reg         ser_rx = 1'b1;  // Línea UART en reposo = '1'

  soc #(
      .ENABLE_TMR    (ENABLE_TMR),
      .ENABLE_REG_ECC(ENABLE_REG_ECC),
      .FIRMWARE_FILE (FIRMWARE_FILE)
  ) uut (
      .clk   (clk),
      .resetn(resetn),
      .trap  (trap),
      .leds  (leds),
      .ser_tx(ser_tx),
      .ser_rx(ser_rx)
  );

  // Secuencia de reset inicial (5 ciclos en bajo; luego soc añade 63 ciclos de POR)
  initial begin
    resetn = 1'b0;
    repeat (5) @(posedge clk);
    resetn = 1'b1;
  end

  // VCD opcional bajo demanda (+DUMP_VCD) para depurar ondas en Surfer sin frenar campañas
  reg dump_vcd_en;
  initial begin
    dump_vcd_en = 1'b0;
    if ($value$plusargs("DUMP_VCD=%d", dump_vcd_en) && dump_vcd_en) begin
      $dumpfile("build/dump.vcd");
      $dumpvars(0, tb_fi_soc);
    end
  end

  // Contadores y banderas de observabilidad para el script TCL
  reg  [31:0] cycle_cnt;
  reg         warmup_done;
  reg  [31:0] warmup_cycle;
  reg  [31:0] trap_cycle;
  wire        done_flag = (leds == 15'h7FFF) && !trap;
  wire        trap_flag = trap;

  always @(posedge clk) begin
    if (!resetn) begin
      cycle_cnt    <= 32'd0;
      warmup_done  <= 1'b0;
      warmup_cycle <= 32'd0;
      trap_cycle   <= 32'd0;
    end else begin
      cycle_cnt <= cycle_cnt + 32'd1;
      if (!warmup_done && (leds == 15'h0001)) begin
        warmup_done  <= 1'b1;
        warmup_cycle <= cycle_cnt;
      end
      if (trap && (trap_cycle == 32'd0)) begin
        trap_cycle <= cycle_cnt;
      end
    end
  end

  // Receptor UART pasivo mediante FSM síncrona (muestrea en el centro exacto de cada bit)
  localparam integer HALF_BIT = UART_BIT_CYCLES / 2;
  localparam [1:0] RX_IDLE = 2'd0;
  localparam [1:0] RX_START = 2'd1;
  localparam [1:0] RX_DATA = 2'd2;
  localparam [1:0] RX_STOP = 2'd3;

  reg [  1:0] rx_state;
  reg [ 15:0] rx_cnt;
  reg [  2:0] rx_bit_idx;
  reg [  7:0] rx_shift;
  // Buffer empaquetado de 64 bytes (512 bits): cabe tanto "RES=XXXXXXXX\r\n" (14 B)
  // como "[HPicoRV32 FATAL] CAUSE=... EPC=...\r\n" (49 B) en una sola lectura examine
  reg [511:0] uart_bytes;
  reg [  7:0] uart_len;

  always @(posedge clk) begin
    if (!resetn || !uut.sys_resetn) begin
      rx_state   <= RX_IDLE;
      rx_cnt     <= 16'd0;
      rx_bit_idx <= 3'd0;
      rx_shift   <= 8'h00;
      uart_bytes <= 512'd0;
      uart_len   <= 8'd0;
    end else begin
      case (rx_state)
        RX_IDLE: begin
          if (ser_tx === 1'b0) begin
            rx_cnt   <= HALF_BIT[15:0] - 16'd1;
            rx_state <= RX_START;
          end
        end

        RX_START: begin
          if (rx_cnt == 16'd0) begin
            if (ser_tx === 1'b0) begin
              rx_cnt     <= UART_BIT_CYCLES[15:0] - 16'd1;
              rx_bit_idx <= 3'd0;
              rx_state   <= RX_DATA;
            end else begin
              // Pulso espúreo < medio bit: vuelve a reposo
              rx_state <= RX_IDLE;
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end

        RX_DATA: begin
          if (rx_cnt == 16'd0) begin
            rx_shift <= {ser_tx, rx_shift[7:1]};
            rx_cnt   <= UART_BIT_CYCLES[15:0] - 16'd1;
            if (rx_bit_idx == 3'd7) begin
              rx_state <= RX_STOP;
            end else begin
              rx_bit_idx <= rx_bit_idx + 3'd1;
            end
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end

        RX_STOP: begin
          if (rx_cnt == 16'd0) begin
            if (uart_len < 8'd64) begin
              uart_bytes[8*uart_len[5:0]+:8] <= rx_shift;
            end
            if (uart_len < 8'd255) begin
              uart_len <= uart_len + 8'd1;
            end
            rx_state <= RX_IDLE;
          end else begin
            rx_cnt <= rx_cnt - 16'd1;
          end
        end

        default: rx_state <= RX_IDLE;
      endcase
    end
  end

  // Modo de prueba directa (golden run) sin script TCL: +STANDALONE
  integer idx;
  reg     standalone_en;
  initial begin
    standalone_en = 1'b0;
    if ($value$plusargs("STANDALONE=%d", standalone_en) && standalone_en) begin
      wait (resetn === 1'b1);
      while (!done_flag && !trap_flag && (cycle_cnt < 32'd200000)) begin
        @(posedge clk);
      end
      $display("=== GOLDEN STANDALONE (TMR=%0d, ECC=%0d) ===", ENABLE_TMR, ENABLE_REG_ECC);
      $display("  done=%0d trap=%0d warmup_cycle=%0d total_cycles=%0d", done_flag, trap_flag,
               warmup_cycle, cycle_cnt);
      $display("  final_pc=0x%08h uart_len=%0d", uut.cpu.reg_pc, uart_len);
      $write("  uart_text=\"");
      for (idx = 0; idx < uart_len && idx < 64; idx = idx + 1) begin
        if (uart_bytes[8*idx+:8] >= 8'h20 && uart_bytes[8*idx+:8] <= 8'h7E)
          $write("%c", uart_bytes[8*idx+:8]);
        else $write("\\x%02h", uart_bytes[8*idx+:8]);
      end
      $display("\"");
      $finish;
    end
  end

endmodule
