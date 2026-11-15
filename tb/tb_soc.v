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

  reg expect_ecc_trap = 1'b0;

  // Aborta inmediatamente si la CPU entra en estado trap no esperado
  always @(posedge clk) begin
    if (uut.sys_resetn && trap && !expect_ecc_trap) begin
      $display("\n[SIM ERROR] La CPU activó TRAP inesperado en %0t ns", $time);
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

  // Inyecta un error de 1 bit en el registro rs1 activo y verifica corrección + auto-scrubbing
  task inject_reg_sbe;
    input integer bit_pos;
    reg [ 4:0] target_reg;
    reg [38:0] golden_word;
    reg [31:0] golden_data;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (uut.cpu.reg_uses_rs1 !== 1'b1) @(negedge clk);

      target_reg = uut.cpu.decoded_rs1;
      golden_word = uut.cpu.cpuregs[target_reg];
      golden_data = uut.cpu.cpuregs_rs1;
      cnt_before = uut.cpu.count_ecc_reg_sbu;

      uut.cpu.cpuregs[target_reg] = golden_word ^ (39'd1 << bit_pos);

      #1;
      if (uut.cpu.cpuregs_rs1 !== golden_data ||
          uut.cpu.regs_sbe1   !== 1'b1        ||
          uut.cpu.regs_dbe1   !== 1'b0        ||
          uut.cpu.cpuregs_scrub1 !== 1'b1) begin
        $display("[ECC FAIL] SBE bit=%0d x%0d @ %0t ns: fallo en correccion combinacional",
                 bit_pos, target_reg, $time);
        $finish;
      end

      @(posedge clk);
      #1;
      if (uut.cpu.cpuregs[target_reg] !== golden_word ||
          uut.cpu.count_ecc_reg_sbu   !== cnt_before + 1) begin
        $display("[ECC FAIL] SBE bit=%0d x%0d @ %0t ns: fallo en auto-scrubbing/CSR", bit_pos,
                 target_reg, $time);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] SBE x%0d bit=%0d | count_ecc_reg_sbu=%0d", $time, target_reg,
               bit_pos, uut.cpu.count_ecc_reg_sbu);
    end
  endtask

  // Comprueba que un DBE en rs2 especulativo NO dispara trap ni falsa telemetría
  task check_reg_dbe_speculative;
    input [38:0] mask2;
    reg [ 4:0] target_reg;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (!(uut.cpu.cpu_state == uut.cpu.cpu_state_ld_rs1 &&
               uut.cpu.reg_uses_rs2 === 1'b0 &&
               uut.cpu.decoded_rs2 != 5'd0 &&
               uut.cpu.decoded_rs2 != uut.cpu.decoded_rs1)) @(negedge clk);

      target_reg  = uut.cpu.decoded_rs2;
      golden_word = uut.cpu.cpuregs[target_reg];
      cnt_before  = uut.cpu.count_ecc_reg_dbu;

      uut.cpu.cpuregs[target_reg] = golden_word ^ mask2;

      #1;
      if (uut.cpu.regs_dbe2 !== 1'b1 || uut.cpu.reg_dbe_event !== 1'b0) begin
        $display("[ECC FAIL] DBE especulativo x%0d @ %0t ns: filtro no bloqueo el falso positivo",
                 target_reg, $time);
        $finish;
      end

      @(posedge clk);
      #1;
      // Restaura el registro para no contaminar lecturas legítimas posteriores
      uut.cpu.cpuregs[target_reg] = golden_word;

      if (uut.cpu.count_ecc_reg_dbu !== cnt_before || trap !== 1'b0) begin
        $display("[ECC FAIL] DBE especulativo x%0d @ %0t ns: contador o trap alterado",
                 target_reg, $time);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] Falso positivo bloqueado en rs2 especulativo (x%0d)",
               $time, target_reg);
    end
  endtask

  // Inyecta un error doble real en rs1 consumido y verifica trap controlado + DBU=1
  task inject_reg_dbe_fatal;
    input [38:0] mask2;
    reg [ 4:0] target_reg;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (uut.cpu.reg_uses_rs1 !== 1'b1) @(negedge clk);

      target_reg  = uut.cpu.decoded_rs1;
      golden_word = uut.cpu.cpuregs[target_reg];
      cnt_before  = uut.cpu.count_ecc_reg_dbu;

      uut.cpu.cpuregs[target_reg] = golden_word ^ mask2;

      #1;
      if (uut.cpu.regs_dbe1 !== 1'b1 || uut.cpu.reg_dbe_event !== 1'b1) begin
        $display("[ECC FAIL] DBE fatal x%0d @ %0t ns: no detectado", target_reg, $time);
        $finish;
      end

      // Ciclo 1: salta a cpu_state_trap y cuenta +1; Ciclos 2..5: activa trap=1 sin recontar
      repeat (5) @(posedge clk);
      #1;
      if (trap !== 1'b1 ||
          uut.cpu.cpu_state         !== uut.cpu.cpu_state_trap ||
          uut.cpu.count_ecc_reg_dbu !== cnt_before + 1         ||
          uut.cpu.mem_valid         !== 1'b0) begin
        $display("[ECC FAIL] DBE fatal x%0d @ %0t ns: trap=%b dbu=%0d (esp %0d)",
                 target_reg, $time, trap, uut.cpu.count_ecc_reg_dbu, cnt_before + 1);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] DBE fatal x%0d -> trap controlado | count_ecc_reg_dbu=%0d",
               $time, target_reg, uut.cpu.count_ecc_reg_dbu);
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

    // 3 SBEs en cpuregs (LSB dato, MSB dato y bit de paridad [35]) + filtro especulativo
    inject_reg_sbe(0);
    inject_reg_sbe(31);
    inject_reg_sbe(35);
    check_reg_dbe_speculative(39'h0000_0003);

    $display("[SEU/ECC OK] Campana recuperable completada sin traps ni corrupcion.");

    // Espera al latido UART Contador = 1 (PC=3 CTRL=4 SBU=3 DBU=0) antes del trap fatal
    wait (leds == 15'h0020);
    expect_ecc_trap = 1'b1;
    inject_reg_dbe_fatal(39'h4000_0001);
    $display("[SIM FIN] Verificacion TMR + ECC cpuregs completada con exito.");
    $finish;
  end

endmodule
