// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       tb_soc.v
// Descripción:  Banco integral del SoC (TMR, ECC cpuregs/IMEM/DMEM y protección Harvard W^X)
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
  end

  // Decodificador UART RX virtual (115200 baudios @ 100 MHz -> 868 ciclos/bit)
  localparam integer BIT_CYCLES = 868;
  localparam integer HALF_BIT = 434;
  reg [7:0] uart_buf;
  reg [7:0] uart_line[0:255];
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
      if (uart_len < 256) begin
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

  reg expect_trap = 1'b0;

  // Aborta inmediatamente si la CPU entra en estado trap no esperado
  always @(posedge clk) begin
    if (uut.sys_resetn && trap && !expect_trap) begin
      $display("\n[SIM ERROR] La CPU activó TRAP inesperado en %0t ns", $time);
      $finish;
    end
  end

  // Límite de seguridad (60 ms @ 100 MHz)
  initial begin
    repeat (6000000) @(posedge clk);
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
               uut.cpu.decoded_rs2 != uut.cpu.decoded_rs1))
      @(negedge clk);

      target_reg = uut.cpu.decoded_rs2;
      golden_word = uut.cpu.cpuregs[target_reg];
      cnt_before = uut.cpu.count_ecc_reg_dbu;

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
        $display("[ECC FAIL] DBE especulativo x%0d @ %0t ns: contador o trap alterado", target_reg,
                 $time);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] Falso positivo bloqueado en rs2 especulativo (x%0d)", $time,
               target_reg);
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

      target_reg = uut.cpu.decoded_rs1;
      golden_word = uut.cpu.cpuregs[target_reg];
      cnt_before = uut.cpu.count_ecc_reg_dbu;

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
        $display("[ECC FAIL] DBE fatal x%0d @ %0t ns: trap=%b dbu=%0d (esp %0d)", target_reg,
                 $time, trap, uut.cpu.count_ecc_reg_dbu, cnt_before + 1);
        $finish;
      end

      // Restaura LUTRAM cpuregs (sin reset síncrono) antes de posibles pruebas tras apply_reset
      uut.cpu.cpuregs[target_reg] = golden_word;
      $display("[ECC PASS @ %0t ns] DBE fatal x%0d -> trap controlado | count_ecc_reg_dbu=%0d",
               $time, target_reg, uut.cpu.count_ecc_reg_dbu);
    end
  endtask

  // Inyecta SBE en la siguiente lectura de IMEM y verifica corrección + auto-scrubbing
  task inject_imem_sbe;
    input integer bit_pos;
    reg [10:0] target_addr;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (!(uut.imem.state === 3'd0 && uut.imem.start_access === 1'b1)) @(negedge clk);

      target_addr = uut.mem_addr[12:2];
      golden_word = uut.imem.u_bram.mem[target_addr];
      cnt_before = uut.count_ecc_imem_sbu;

      uut.imem.u_bram.mem[target_addr] = golden_word ^ (39'd1 << bit_pos);

      @(posedge clk);  // T0: BRAM lee palabra corrupta
      @(posedge clk);  // T1: decodifica y activa imem_sbe
      #1;
      if (uut.imem_sbe !== 1'b1 || uut.imem_dbe !== 1'b0 ||
          uut.imem_rdata !== golden_word[31:0] || uut.imem_ready !== 1'b0) begin
        $display("[ECC FAIL] IMEM SBE addr=0x%03h bit=%0d @ %0t ns", target_addr, bit_pos, $time);
        $finish;
      end

      @(posedge clk);  // T2: auto-scrubbing escribe en BRAM + libera bus
      #1;
      if (uut.imem.u_bram.mem[target_addr] !== golden_word ||
          uut.imem_ready !== 1'b1 ||
          uut.count_ecc_imem_sbu !== cnt_before + 1 ||
          trap !== 1'b0) begin
        $display("[ECC FAIL] IMEM SBE scrub addr=0x%03h @ %0t ns", target_addr, $time);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] IMEM SBE addr=0x%03h bit=%0d | count_ecc_imem_sbu=%0d", $time,
               target_addr, bit_pos, uut.count_ecc_imem_sbu);
    end
  endtask

  // Inyecta SBE en la siguiente lectura de DMEM y verifica corrección + auto-scrubbing
  task inject_dmem_sbe;
    input integer bit_pos;
    reg [10:0] target_addr;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (!(uut.dmem.state === 3'd0 &&
               uut.dmem.start_access === 1'b1 &&
               uut.mem_wstrb === 4'b0000))
      @(negedge clk);

      target_addr = uut.mem_addr[12:2];
      golden_word = uut.dmem.u_bram.mem[target_addr];
      cnt_before = uut.count_ecc_dmem_sbu;

      uut.dmem.u_bram.mem[target_addr] = golden_word ^ (39'd1 << bit_pos);

      @(posedge clk);  // T0: BRAM lee palabra corrupta
      @(posedge clk);  // T1: decodifica y activa dmem_sbe
      #1;
      if (uut.dmem_sbe !== 1'b1 || uut.dmem_dbe !== 1'b0 ||
          uut.dmem_rdata !== golden_word[31:0] || uut.dmem_ready !== 1'b0) begin
        $display("[ECC FAIL] DMEM SBE addr=0x%03h bit=%0d @ %0t ns", target_addr, bit_pos, $time);
        $finish;
      end

      @(posedge clk);  // T2: auto-scrubbing escribe en BRAM + libera bus
      #1;
      if (uut.dmem.u_bram.mem[target_addr] !== golden_word ||
          uut.dmem_ready !== 1'b1 ||
          uut.count_ecc_dmem_sbu !== cnt_before + 1 ||
          trap !== 1'b0) begin
        $display("[ECC FAIL] DMEM SBE scrub addr=0x%03h @ %0t ns", target_addr, $time);
        $finish;
      end

      $display("[ECC PASS @ %0t ns] DMEM SBE addr=0x%03h bit=%0d | count_ecc_dmem_sbu=%0d", $time,
               target_addr, bit_pos, uut.count_ecc_dmem_sbu);
    end
  endtask

  // Resetea el SoC y limpia expect_trap solo tras caer sys_resetn (evita falsa alarma)
  task apply_reset;
    begin
      @(negedge clk);
      resetn = 1'b0;
      wait (uut.sys_resetn === 1'b0);
      expect_trap = 1'b0;
      repeat (10) @(posedge clk);
      @(negedge clk);
      resetn = 1'b1;
      wait (uut.sys_resetn === 1'b1);
    end
  endtask

  // Inyecta DBE fatal en lectura de IMEM -> verifica trap=1 y contador MMIO=1
  task inject_imem_dbe_fatal;
    input [38:0] mask2;
    reg [10:0] target_addr;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (!(uut.imem.state === 3'd0 && uut.imem.start_access === 1'b1)) @(negedge clk);

      target_addr = uut.mem_addr[12:2];
      golden_word = uut.imem.u_bram.mem[target_addr];
      cnt_before = uut.count_ecc_imem_dbu;

      uut.imem.u_bram.mem[target_addr] = golden_word ^ mask2;

      @(posedge clk);  // T0: BRAM lee palabra corrupta
      @(posedge clk);  // T1: imem_dbe=1 y ready=1
      #1;
      if (uut.imem_dbe !== 1'b1 || uut.imem_sbe !== 1'b0 || uut.imem_ready !== 1'b1 ||
          uut.imem.u_bram.mem[target_addr] !== (golden_word ^ mask2)) begin
        $display("[ECC FAIL] IMEM DBE addr=0x%03h @ %0t ns", target_addr, $time);
        $finish;
      end

      @(posedge clk);  // T2: soc registra ecc_fault_r -> trap=1 e incrementa DBU
      #1;
      if (trap !== 1'b1 || uut.count_ecc_imem_dbu !== cnt_before + 1) begin
        $display("[ECC FAIL] IMEM DBE trap=%b dbu=%0d @ %0t ns", trap, uut.count_ecc_imem_dbu,
                 $time);
        $finish;
      end

      // Restaura IMEM antes del siguiente reset para probar DMEM limpio
      uut.imem.u_bram.mem[target_addr] = golden_word;
      $display("[ECC PASS @ %0t ns] IMEM DBE fatal addr=0x%03h -> trap=1 | imem_dbu=%0d", $time,
               target_addr, uut.count_ecc_imem_dbu);
    end
  endtask

  // Inyecta DBE fatal en lectura de DMEM -> verifica trap=1 y contador MMIO=1
  task inject_dmem_dbe_fatal;
    input [38:0] mask2;
    reg [10:0] target_addr;
    reg [38:0] golden_word;
    reg [31:0] cnt_before;
    begin
      @(negedge clk);
      while (!(uut.dmem.state === 3'd0 &&
               uut.dmem.start_access === 1'b1 &&
               uut.mem_wstrb === 4'b0000))
      @(negedge clk);

      target_addr = uut.mem_addr[12:2];
      golden_word = uut.dmem.u_bram.mem[target_addr];
      cnt_before = uut.count_ecc_dmem_dbu;

      uut.dmem.u_bram.mem[target_addr] = golden_word ^ mask2;

      @(posedge clk);  // T0: BRAM lee palabra corrupta
      @(posedge clk);  // T1: dmem_dbe=1 y ready=1
      #1;
      if (uut.dmem_dbe !== 1'b1 || uut.dmem_sbe !== 1'b0 || uut.dmem_ready !== 1'b1) begin
        $display("[ECC FAIL] DMEM DBE addr=0x%03h @ %0t ns", target_addr, $time);
        $finish;
      end

      @(posedge clk);  // T2: soc registra ecc_fault_r -> trap=1 e incrementa DBU
      #1;
      if (trap !== 1'b1 || uut.count_ecc_dmem_dbu !== cnt_before + 1) begin
        $display("[ECC FAIL] DMEM DBE trap=%b dbu=%0d @ %0t ns", trap, uut.count_ecc_dmem_dbu,
                 $time);
        $finish;
      end

      // Restaura DMEM antes del siguiente reset para las pruebas Harvard W^X
      uut.dmem.u_bram.mem[target_addr] = golden_word;
      $display("[ECC PASS @ %0t ns] DMEM DBE fatal addr=0x%03h -> trap=1 | dmem_dbu=%0d", $time,
               target_addr, uut.count_ecc_dmem_dbu);
    end
  endtask

  // Comprueba que un fetch de instrucción en DMEM (0x0000_2000) activa harv_fault_r y trap=1
  task check_harvard_exec_dmem;
    begin
      @(negedge clk);
      while (!(uut.cpu.mem_la_read === 1'b1 &&
               (uut.cpu.mem_do_rinst === 1'b1 || uut.cpu.mem_do_prefetch === 1'b1) &&
               !(uut.cpu.latched_store && uut.cpu.latched_branch)))
      @(negedge clk);

      uut.cpu.reg_next_pc_r0 = 32'h0000_2000;
      uut.cpu.reg_next_pc_r1 = 32'h0000_2000;
      uut.cpu.reg_next_pc_r2 = 32'h0000_2000;

      #1;
      if (uut.cpu.mem_la_addr !== 32'h0000_2000) begin
        $display("[HARV FAIL] Fetch DMEM @ %0t ns: mem_la_addr=%h", $time, uut.cpu.mem_la_addr);
        $finish;
      end

      @(posedge clk);  // T0: el bus expone mem_valid=1, mem_instr=1, mem_addr=0x2000
      #1;
      if (uut.mem_valid !== 1'b1 || uut.mem_instr !== 1'b1 ||
          uut.mem_addr !== 32'h0000_2000 || uut.harv_err !== 1'b1 ||
          uut.dmem_sel !== 1'b0 || uut.imem_sel !== 1'b0) begin
        $display("[HARV FAIL] Fetch DMEM T0 @ %0t ns: valid=%b instr=%b addr=%h harv_err=%b",
                 $time, uut.mem_valid, uut.mem_instr, uut.mem_addr, uut.harv_err);
        $finish;
      end

      @(posedge clk);  // T1: soc enclava harv_fault_r -> trap=1 y responde mem_ready=1
      #1;
      if (uut.harv_fault_r !== 1'b1 || trap !== 1'b1 || uut.mem_ready !== 1'b1) begin
        $display("[HARV FAIL] Fetch DMEM T1 @ %0t ns: harv_fault=%b trap=%b ready=%b",
                 $time, uut.harv_fault_r, trap, uut.mem_ready);
        $finish;
      end

      $display("[HARV PASS @ %0t ns] Fetch en DMEM (0x00002000) bloqueado -> harv_fault_r=1, trap=1",
               $time);
    end
  endtask

  // Comprueba que una escritura hacia IMEM (0x0000_0000) queda bloqueada y activa trap=1
  task check_harvard_write_imem;
    reg [38:0] golden_imem0;
    begin
      @(negedge clk);
      while (uut.cpu.mem_la_write !== 1'b1) @(negedge clk);

      golden_imem0 = uut.imem.u_bram.mem[11'd0];
      uut.cpu.reg_op1 = 32'h0000_0000;

      #1;
      if (uut.cpu.mem_la_addr !== 32'h0000_0000) begin
        $display("[HARV FAIL] Escritura IMEM @ %0t ns: mem_la_addr=%h", $time,
                 uut.cpu.mem_la_addr);
        $finish;
      end

      @(posedge clk);  // T0: el bus expone mem_valid=1, wstrb!=0, mem_addr=0x0000
      #1;
      if (uut.mem_valid !== 1'b1 || (|uut.mem_wstrb) !== 1'b1 ||
          uut.mem_addr !== 32'h0000_0000 || uut.harv_err !== 1'b1 ||
          uut.imem_sel !== 1'b0 || uut.dmem_sel !== 1'b0) begin
        $display("[HARV FAIL] Escritura IMEM T0 @ %0t ns: valid=%b wstrb=%b addr=%h harv_err=%b",
                 $time, uut.mem_valid, uut.mem_wstrb, uut.mem_addr, uut.harv_err);
        $finish;
      end

      @(posedge clk);  // T1: soc enclava harv_fault_r -> trap=1, mem_ready=1 e IMEM intacta
      #1;
      if (uut.harv_fault_r !== 1'b1 || trap !== 1'b1 || uut.mem_ready !== 1'b1 ||
          uut.imem.u_bram.mem[11'd0] !== golden_imem0) begin
        $display("[HARV FAIL] Escritura IMEM T1 @ %0t ns: harv_fault=%b trap=%b ready=%b",
                 $time, uut.harv_fault_r, trap, uut.mem_ready);
        $finish;
      end

      $display(
          "[HARV PASS @ %0t ns] Escritura en IMEM (0x00000000) bloqueada e IMEM intacta -> trap=1",
          $time);
    end
  endtask

  // Campaña integral: TMR (PC+CTRL) + ECC recuperable (cpuregs+IMEM+DMEM) + DBE fatales + Harvard W^X
  initial begin
    apply_reset;
    wait (leds == 15'h0001);

    // 1. TMR PC y Control
    inject_pc_seu(0, 32'h0000_0004);
    inject_pc_seu(1, 32'hA5A5_0001);
    inject_pc_seu(4, 32'h0000_0100);
    inject_ctrl_seu(0, 8'h08);
    inject_ctrl_seu(2, 8'hFF);
    inject_ctrl_seu(4, 8'h03);
    inject_ctrl_seu(6, 8'h1F);

    // 2. ECC cpuregs + filtro especulativo
    inject_reg_sbe(0);
    inject_reg_sbe(31);
    inject_reg_sbe(35);
    check_reg_dbe_speculative(39'h0000_0003);

    // 3. ECC IMEM y DMEM recuperables (dato y bit de paridad)
    inject_imem_sbe(3);
    inject_imem_sbe(33);
    inject_dmem_sbe(12);
    inject_dmem_sbe(37);

    $display("[SEU/ECC OK] Campana recuperable completada sin traps ni corrupcion.");

    // Espera al latido UART Contador = 1 para validar PC=3 CTRL=4 SBU=3 ISBU=2 DSBU=2 por serie
    wait (leds == 15'h0020);

    // 4. Tres pruebas de DBE fatal separadas por reset rápido
    expect_trap = 1'b1;
    inject_reg_dbe_fatal(39'h4000_0001);

    apply_reset;
    expect_trap = 1'b1;
    inject_imem_dbe_fatal(39'h0000_0003);

    apply_reset;
    expect_trap = 1'b1;
    inject_dmem_dbe_fatal(39'h0000_0003);

    // 5. Dos pruebas de violación Harvard W^X (ejecución en DMEM y escritura en IMEM)
    apply_reset;
    expect_trap = 1'b1;
    check_harvard_exec_dmem;

    apply_reset;
    expect_trap = 1'b1;
    check_harvard_write_imem;

    $display("[SIM FIN] Verificacion integral TMR + ECC + Harvard W^X completada con exito.");
    $finish;
  end

endmodule
