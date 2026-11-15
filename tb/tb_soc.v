// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       tb_soc.v
// Descripción:  Banco de pruebas del SoC base (arranque, UART TX, LEDs y trap)
// Reloj/Reset:  clk simulado a 100 MHz | resetn activo bajo
// =============================================================================

`timescale 1ns / 1ps

module tb_soc;

  reg clk = 1'b1;
  always #5 clk = ~clk;  // Reloj de 100 MHz (período de 10 ns)

  reg         resetn = 1'b0;

  wire        trap;
  wire [14:0] leds;
  wire        ser_tx;
  reg         ser_rx = 1'b1;  // Nivel en reposo de UART es alto

  soc uut (
      .clk   (clk),
      .resetn(resetn),
      .trap  (trap),
      .leds  (leds),
      .ser_tx(ser_tx),
      .ser_rx(ser_rx)
  );

  initial begin
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_soc);
    repeat (10) @(posedge clk);
    resetn <= 1'b1;
  end

  // Decodificador UART RX virtual (115200 baudios @ 100 MHz -> 868 ciclos/bit)
  localparam integer BIT_CYCLES = 868;
  localparam integer HALF_BIT = 434;
  reg [7:0] uart_buf;
  reg [7:0] uart_line[0:127];
  integer uart_len = 0;
  integer k;

  always begin
    wait (uut.sys_resetn === 1'b1);
    @(negedge ser_tx);
    repeat (HALF_BIT) @(posedge clk);

    repeat (8) begin
      repeat (BIT_CYCLES) @(posedge clk);
      uart_buf = {ser_tx, uart_buf[7:1]};
    end

    repeat (BIT_CYCLES) @(posedge clk);
    if (uart_buf == 8'h0a) begin
      $write("[UART] ");
      for (k = 0; k < uart_len; k = k + 1) $write("%c", uart_line[k]);
      $write("\n");
      $fflush;
      uart_len = 0;
    end else if (uart_buf != 8'h0d) begin
      if (uart_len < 128) begin
        uart_line[uart_len] = uart_buf;
        uart_len = uart_len + 1;
      end
    end
  end

  // Monitor de cambios en el registro de LEDs tras liberar el reset interno
  always @(leds) begin
    if (uut.sys_resetn === 1'b1) begin
      $display("[%0t ns] LEDs = 15'b%015b (0x%04h)", $time, leds, leds);
    end
  end

  // Aborta inmediatamente si la CPU entra en estado trap
  always @(posedge clk) begin
    if (uut.sys_resetn && trap) begin
      $display("\n[SIM ERROR] La CPU activó TRAP en %0t ns", $time);
      $finish;
    end
  end

  // Límite de seguridad (30 ms @ 100 MHz)
  initial begin
    repeat (5000000) @(posedge clk);
    $display("\n[SIM FIN] Timeout alcanzado limpiamente sin trap.");
    $finish;
  end

  // target: 0..2 -> reg_pc_r0..r2 | 3..5 -> reg_next_pc_r0..r2
  task inject_pc_seu;
    input integer target;
    input [31:0] mask;
    reg [31:0] golden;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      golden = (target < 3) ? uut.cpu.reg_pc : uut.cpu.reg_next_pc;
      cnt_before = uut.cpu.count_tmr_pc;

      case (target)
        0: uut.cpu.reg_pc_r0 = uut.cpu.reg_pc_r0 ^ mask;
        1: uut.cpu.reg_pc_r1 = uut.cpu.reg_pc_r1 ^ mask;
        2: uut.cpu.reg_pc_r2 = uut.cpu.reg_pc_r2 ^ mask;
        3: uut.cpu.reg_next_pc_r0 = uut.cpu.reg_next_pc_r0 ^ mask;
        4: uut.cpu.reg_next_pc_r1 = uut.cpu.reg_next_pc_r1 ^ mask;
        5: uut.cpu.reg_next_pc_r2 = uut.cpu.reg_next_pc_r2 ^ mask;
      endcase

      #1;
      if (((target < 3) ? uut.cpu.reg_pc : uut.cpu.reg_next_pc) !== golden ||
          uut.cpu.tmr_pc_err !== 1'b1) begin
        $display("[SEU FAIL] PC target=%0d @ %0t ns: votacion incorrecta", target, $time);
        $finish;
      end

      @(posedge clk);
      #1;
      if (uut.cpu.reg_pc_r0 !== uut.cpu.reg_pc_r1 ||
          uut.cpu.reg_pc_r1 !== uut.cpu.reg_pc_r2 ||
          uut.cpu.reg_next_pc_r0 !== uut.cpu.reg_next_pc_r1 ||
          uut.cpu.reg_next_pc_r1 !== uut.cpu.reg_next_pc_r2 ||
          uut.cpu.tmr_pc_err !== 1'b0 ||
          uut.cpu.count_tmr_pc !== cnt_before + 1) begin
        $display("[SEU FAIL] PC target=%0d @ %0t ns: fallo en self-healing/CSR", target, $time);
        $finish;
      end

      $display("[SEU PASS @ %0t ns] PC target=%0d mask=0x%08h | count_tmr_pc=%0d", $time, target,
               mask, uut.cpu.count_tmr_pc);
    end
  endtask

  // target: 0..2 -> cpu_state_r0..r2 (8b) | 3..5 -> mem_state_r0..r2 (2b) | 6..8 -> latched_rd_r0..r2 (5b)
  task inject_ctrl_seu;
    input integer target;
    input [7:0] mask;
    reg [ 7:0] golden;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      golden = (target < 3) ? uut.cpu.cpu_state :
               (target < 6) ? {6'b0, uut.cpu.mem_state} :
                              {3'b0, uut.cpu.latched_rd};
      cnt_before = uut.cpu.count_tmr_ctrl;

      case (target)
        0: uut.cpu.cpu_state_r0 = uut.cpu.cpu_state_r0 ^ mask;
        1: uut.cpu.cpu_state_r1 = uut.cpu.cpu_state_r1 ^ mask;
        2: uut.cpu.cpu_state_r2 = uut.cpu.cpu_state_r2 ^ mask;
        3: uut.cpu.mem_state_r0 = uut.cpu.mem_state_r0 ^ mask[1:0];
        4: uut.cpu.mem_state_r1 = uut.cpu.mem_state_r1 ^ mask[1:0];
        5: uut.cpu.mem_state_r2 = uut.cpu.mem_state_r2 ^ mask[1:0];
        6: uut.cpu.latched_rd_r0 = uut.cpu.latched_rd_r0 ^ mask[4:0];
        7: uut.cpu.latched_rd_r1 = uut.cpu.latched_rd_r1 ^ mask[4:0];
        8: uut.cpu.latched_rd_r2 = uut.cpu.latched_rd_r2 ^ mask[4:0];
      endcase

      #1;
      if (((target < 3) ? uut.cpu.cpu_state :
           (target < 6) ? {6'b0, uut.cpu.mem_state} :
                          {3'b0, uut.cpu.latched_rd}) !== golden ||
          uut.cpu.tmr_ctrl_err !== 1'b1) begin
        $display("[SEU FAIL] CTRL target=%0d @ %0t ns: votacion incorrecta", target, $time);
        $finish;
      end

      @(posedge clk);
      #1;
      if (uut.cpu.cpu_state_r0  !== uut.cpu.cpu_state_r1  ||
          uut.cpu.cpu_state_r1  !== uut.cpu.cpu_state_r2  ||
          uut.cpu.mem_state_r0  !== uut.cpu.mem_state_r1  ||
          uut.cpu.mem_state_r1  !== uut.cpu.mem_state_r2  ||
          uut.cpu.latched_rd_r0 !== uut.cpu.latched_rd_r1 ||
          uut.cpu.latched_rd_r1 !== uut.cpu.latched_rd_r2 ||
          uut.cpu.tmr_ctrl_err  !== 1'b0                  ||
          uut.cpu.count_tmr_ctrl !== cnt_before + 1) begin
        $display("[SEU FAIL] CTRL target=%0d @ %0t ns: fallo en self-healing/CSR", target, $time);
        $finish;
      end

      $display("[SEU PASS @ %0t ns] CTRL target=%0d mask=0x%02h | count_tmr_ctrl=%0d", $time,
               target, mask, uut.cpu.count_tmr_ctrl);
    end
  endtask

  // Campaña de inyección SEU entre el primer y el segundo latido UART (entre LED 0x0001 y 0x0010)
  initial begin
    wait (uut.sys_resetn === 1'b1);
    wait (leds == 15'h0001);

    // 3 SEUs en dominio PC (1-bit y multi-bit en misma réplica)
    inject_pc_seu(0, 32'h0000_0004);
    inject_pc_seu(1, 32'hA5A5_0001);
    inject_pc_seu(4, 32'h0000_0100);

    // 4 SEUs en dominio Control (cpu_state, mem_state, latched_rd)
    inject_ctrl_seu(0, 8'h08);
    inject_ctrl_seu(2, 8'hFF);
    inject_ctrl_seu(4, 8'h03);
    inject_ctrl_seu(6, 8'h1F);

    $display("[SEU OK] Campana completada sin traps ni corrupcion.");
  end

endmodule
