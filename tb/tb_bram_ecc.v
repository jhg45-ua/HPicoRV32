// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       tb_bram_ecc.v
// Descripción:  Testbench unitario para bram_ecc (sw, RMW sb/sh, scrubbing, DBE)
// Reloj/Reset:  clk simulado a 100 MHz | resetn activo bajo
// =============================================================================

`timescale 1ns / 1ps

module tb_bram_ecc;

  reg clk = 1'b1;
  always #5 clk = ~clk;  // 100 MHz

  reg            resetn;

  // Bus para instancia lectura/escritura (tipo DMEM)
  reg            rw_valid;
  reg     [ 3:0] rw_wstrb;
  reg     [ 5:0] rw_addr;
  reg     [31:0] rw_wdata;
  wire    [31:0] rw_rdata;
  wire           rw_ready;
  wire           rw_sbe;
  wire           rw_dbe;

  // Bus para instancia solo lectura (tipo IMEM)
  reg            ro_valid;
  reg     [ 3:0] ro_wstrb;
  reg     [ 3:0] ro_addr;
  reg     [31:0] ro_wdata;
  wire    [31:0] ro_rdata;
  wire           ro_ready;
  wire           ro_sbe;
  wire           ro_dbe;

  integer        errors;

  bram_ecc #(
      .WORDS    (64),
      .ADDR_BITS(6),
      .READ_ONLY(1'b0),
      .USE_INIT (1'b0)
  ) dut_rw (
      .clk    (clk),
      .resetn (resetn),
      .valid_i(rw_valid),
      .wstrb_i(rw_wstrb),
      .addr_i (rw_addr),
      .wdata_i(rw_wdata),
      .rdata_o(rw_rdata),
      .ready_o(rw_ready),
      .sbe_o  (rw_sbe),
      .dbe_o  (rw_dbe)
  );

  bram_ecc #(
      .WORDS    (16),
      .ADDR_BITS(4),
      .READ_ONLY(1'b1),
      .USE_INIT (1'b0)
  ) dut_ro (
      .clk    (clk),
      .resetn (resetn),
      .valid_i(ro_valid),
      .wstrb_i(ro_wstrb),
      .addr_i (ro_addr),
      .wdata_i(ro_wdata),
      .rdata_o(ro_rdata),
      .ready_o(ro_ready),
      .sbe_o  (ro_sbe),
      .dbe_o  (ro_dbe)
  );

  // Ejecuta una transacción completa sobre dut_rw midiendo ciclos y pulsos ECC
  task do_rw;
    input [3:0] wstrb;
    input [5:0] addr;
    input [31:0] wdata;
    output [31:0] rdata;
    output integer sbe_cnt;
    output integer dbe_cnt;
    output integer cycles;
    reg done;
    begin
      sbe_cnt = 0;
      dbe_cnt = 0;
      cycles  = 0;
      done    = 1'b0;
      rdata   = 32'h0;

      @(negedge clk);
      rw_valid = 1'b1;
      rw_wstrb = wstrb;
      rw_addr  = addr;
      rw_wdata = wdata;

      while (!done) begin
        @(posedge clk);
        #1;
        cycles = cycles + 1;
        if (rw_sbe === 1'b1) sbe_cnt = sbe_cnt + 1;
        if (rw_dbe === 1'b1) dbe_cnt = dbe_cnt + 1;
        if (rw_ready === 1'b1) begin
          rdata = rw_rdata;
          done  = 1'b1;
        end else if (cycles > 10) begin
          $display("[FAIL] Timeout en dut_rw addr=%0d", addr);
          errors = errors + 1;
          done   = 1'b1;
        end
      end

      @(negedge clk);
      rw_valid = 1'b0;
      rw_wstrb = 4'b0000;
    end
  endtask

  // Ejecuta una transacción sobre dut_ro (para probar READ_ONLY=1 y scrubbing en IMEM)
  task do_ro;
    input [3:0] wstrb;
    input [3:0] addr;
    input [31:0] wdata;
    output [31:0] rdata;
    output integer sbe_cnt;
    output integer dbe_cnt;
    reg done;
    integer cycles;
    begin
      sbe_cnt = 0;
      dbe_cnt = 0;
      cycles  = 0;
      done    = 1'b0;
      rdata   = 32'h0;

      @(negedge clk);
      ro_valid = 1'b1;
      ro_wstrb = wstrb;
      ro_addr  = addr;
      ro_wdata = wdata;

      while (!done) begin
        @(posedge clk);
        #1;
        cycles = cycles + 1;
        if (ro_sbe === 1'b1) sbe_cnt = sbe_cnt + 1;
        if (ro_dbe === 1'b1) dbe_cnt = dbe_cnt + 1;
        if (ro_ready === 1'b1) begin
          rdata = ro_rdata;
          done  = 1'b1;
        end else if (cycles > 10) begin
          $display("[FAIL] Timeout en dut_ro addr=%0d", addr);
          errors = errors + 1;
          done   = 1'b1;
        end
      end

      @(negedge clk);
      ro_valid = 1'b0;
      ro_wstrb = 4'b0000;
    end
  endtask

  reg [31:0] rd;
  reg [38:0] golden_raw;
  integer    sbe_c;
  integer    dbe_c;
  integer    cyc;

  initial begin
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_bram_ecc);

    errors   = 0;
    resetn   = 1'b0;
    rw_valid = 1'b0;
    rw_wstrb = 4'b0000;
    rw_addr  = 6'd0;
    rw_wdata = 32'h0;
    ro_valid = 1'b0;
    ro_wstrb = 4'b0000;
    ro_addr  = 4'd0;
    ro_wdata = 32'h0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    resetn = 1'b1;

    // 1. Escritura sw (1 ciclo) + lectura nominal (2 ciclos)
    do_rw(4'b1111, 6'd1, 32'h1122_3344, rd, sbe_c, dbe_c, cyc);
    if (cyc !== 1 || sbe_c !== 0 || dbe_c !== 0) errors = errors + 1;
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'h1122_3344 || cyc !== 2 || sbe_c !== 0 || dbe_c !== 0) begin
      $display("[FAIL T1] sw/lw rdata=%h cyc=%0d", rd, cyc);
      errors = errors + 1;
    end else $display("[PASS] T1: sw (1c) + lectura nominal (2c)");

    // 2. RMW sb/sh (3 ciclos) en palabra existente y en palabra virgen a 0
    do_rw(4'b0010, 6'd1, 32'hFFFF_AAFF, rd, sbe_c, dbe_c, cyc);
    if (cyc !== 3) errors = errors + 1;
    do_rw(4'b1100, 6'd1, 32'hCAFE_0000, rd, sbe_c, dbe_c, cyc);
    if (cyc !== 3) errors = errors + 1;
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'hCAFE_AA44 || sbe_c !== 0 || dbe_c !== 0) begin
      $display("[FAIL T2a] RMW addr=1 rdata=%h", rd);
      errors = errors + 1;
    end

    do_rw(4'b0100, 6'd2, 32'h005A_0000, rd, sbe_c, dbe_c, cyc);
    do_rw(4'b0000, 6'd2, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'h005A_0000 || sbe_c !== 0 || dbe_c !== 0) begin
      $display("[FAIL T2b] RMW sobre palabra a 0 rdata=%h", rd);
      errors = errors + 1;
    end else $display("[PASS] T2: RMW sb/sh (3c) validado");

    // 3. SBE en dato (bit 7) y en paridad (bit 36) + auto-scrubbing real
    golden_raw = dut_rw.u_bram.mem[6'd1];
    dut_rw.u_bram.mem[6'd1] = golden_raw ^ (39'd1 << 7);
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'hCAFE_AA44 || sbe_c !== 1 || dbe_c !== 0 || cyc !== 3 ||
        dut_rw.u_bram.mem[6'd1] !== golden_raw) begin
      $display("[FAIL T3a] SBE dato rdata=%h sbe=%0d cyc=%0d", rd, sbe_c, cyc);
      errors = errors + 1;
    end
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'hCAFE_AA44 || sbe_c !== 0 || cyc !== 2) errors = errors + 1;

    dut_rw.u_bram.mem[6'd1] = golden_raw ^ (39'd1 << 36);
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'hCAFE_AA44 || sbe_c !== 1 || dbe_c !== 0 || cyc !== 3 ||
        dut_rw.u_bram.mem[6'd1] !== golden_raw) begin
      $display("[FAIL T3b] SBE paridad sbe=%0d cyc=%0d", sbe_c, cyc);
      errors = errors + 1;
    end else $display("[PASS] T3: SBE dato/paridad corregido y auto-scrubbed");

    // 4. RMW sb sobre palabra con SBE previo en byte 3 intacto (bit 28)
    dut_rw.u_bram.mem[6'd1] = golden_raw ^ (39'd1 << 28);
    do_rw(4'b0001, 6'd1, 32'h0000_0077, rd, sbe_c, dbe_c, cyc);
    if (sbe_c !== 1 || dbe_c !== 0 || cyc !== 3) errors = errors + 1;
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (rd !== 32'hCAFE_AA77 || sbe_c !== 0 || dbe_c !== 0) begin
      $display("[FAIL T4] RMW sobre SBE previo rdata=%h sbe=%0d", rd, sbe_c);
      errors = errors + 1;
    end else $display("[PASS] T4: RMW sobre SBE previo reparo byte intacto");

    // 5. DBE en lectura y abortado seguro en RMW (sin sobrescribir BRAM)
    golden_raw = dut_rw.u_bram.mem[6'd1];
    dut_rw.u_bram.mem[6'd1] = golden_raw ^ 39'h0000_0003;
    do_rw(4'b0000, 6'd1, 32'h0, rd, sbe_c, dbe_c, cyc);
    if (sbe_c !== 0 || dbe_c !== 1 || cyc !== 2 ||
        dut_rw.u_bram.mem[6'd1] !== (golden_raw ^ 39'h0000_0003)) begin
      $display("[FAIL T5a] DBE lectura sbe=%0d dbe=%0d", sbe_c, dbe_c);
      errors = errors + 1;
    end
    do_rw(4'b0001, 6'd1, 32'h0000_0099, rd, sbe_c, dbe_c, cyc);
    if (sbe_c !== 0 || dbe_c !== 1 || cyc !== 2 ||
        dut_rw.u_bram.mem[6'd1] !== (golden_raw ^ 39'h0000_0003)) begin
      $display("[FAIL T5b] DBE RMW deberia abortar escritura sbe=%0d dbe=%0d", sbe_c, dbe_c);
      errors = errors + 1;
    end else $display("[PASS] T5: DBE lectura + abortado RMW sin corrupcion");

    // 6. Modo READ_ONLY=1 (IMEM): ignora sw de bus, pero permite scrubbing en SBE
    dut_ro.u_bram.mem[4'd0] = 39'h48_0000_0413;
    do_ro(4'b1111, 4'd0, 32'hDEAD_BEEF, rd, sbe_c, dbe_c);
    if (rd !== 32'h0000_0413 || dut_ro.u_bram.mem[4'd0] !== 39'h48_0000_0413) begin
      $display("[FAIL T6a] READ_ONLY permitio escritura externa");
      errors = errors + 1;
    end
    dut_ro.u_bram.mem[4'd0] = 39'h48_0000_0413 ^ (39'd1 << 34);
    do_ro(4'b0000, 4'd0, 32'h0, rd, sbe_c, dbe_c);
    if (rd !== 32'h0000_0413 || sbe_c !== 1 || dbe_c !== 0 ||
        dut_ro.u_bram.mem[4'd0] !== 39'h48_0000_0413) begin
      $display("[FAIL T6b] READ_ONLY fallo scrubbing rdata=%h sbe=%0d", rd, sbe_c);
      errors = errors + 1;
    end else $display("[PASS] T6: READ_ONLY protege bus y realiza scrubbing");

    if (errors == 0) $display("\n[OK] bram_ecc verificado: 6/6 pruebas superadas.");
    else $display("\n[ERROR] %0d errores en bram_ecc.", errors);

    $finish;
  end

endmodule
