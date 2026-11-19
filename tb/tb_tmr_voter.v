// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       tb_tmr_voter.v
// Descripción:  Testbench unitario para tmr_voter con inyección de fallos XOR
// Reloj/Reset:  Sin reloj (estímulos combinacionales)
// =============================================================================

`timescale 1ns / 1ps

module tb_tmr_voter;

  localparam integer WIDTH = 32;

  reg [WIDTH-1:0] r0, r1, r2;
  wire [WIDTH-1:0] voted;
  wire err;

  reg [WIDTH-1:0] golden;
  integer errors = 0;

  tmr_voter #(
      .WIDTH(WIDTH)
  ) uut (
      .r0(r0),
      .r1(r1),
      .r2(r2),
      .voted(voted),
      .err(err)
  );

  // Inyecta bit-flips mediante máscaras XOR sobre cada réplica y verifica salida
  task inject_and_check(input [WIDTH-1:0] base_val, input [WIDTH-1:0] mask0,
                        input [WIDTH-1:0] mask1, input [WIDTH-1:0] mask2,
                        input [WIDTH-1:0] expected_voted, input expected_err);
    begin
      golden = base_val;
      r0 = base_val ^ mask0;
      r1 = base_val ^ mask1;
      r2 = base_val ^ mask2;
      #1;  // Espera un delta de tiempo para que se propague la señal

      if (voted !== expected_voted || err !== expected_err) begin
        $display("[FAIL @ %0t ns] r0=%h r1=%h r2=%h | voted=%h (esp %h) err=%b (esp %b)", $time,
                 r0, r1, r2, voted, expected_voted, err, expected_err);
        errors = errors + 1;
      end else begin
        $display("[PASS @ %0t ns] r0=%h r1=%h r2=%h | voted=%h (esp %h) err=%b (esp %b)", $time,
                 r0, r1, r2, voted, expected_voted, err, expected_err);
      end
      #9;  // Esperar un tiempo adicional para verlo bien en la simulación
    end
  endtask

  initial begin
    // Volcamos las señales a un archivo VCD para su visualización y las variables de simulación
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_tmr_voter);

    // 1. Funcionamiento nominal sin fallos
    inject_and_check(32'hCAFE_BABE, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'hCAFE_BABE,
                     1'b0);

    // 2. SEU de 1 bit en r0 -> votador corrige, err=1
    inject_and_check(32'hCAFE_BABE, 32'h0000_0001, 32'h0000_0000, 32'h0000_0000, 32'hCAFE_BABE,
                     1'b1);

    // 3. Fallo múltiple dentro de una sola réplica (r1) -> votador corrige, err=1
    inject_and_check(32'h1234_5678, 32'h0000_0000, 32'hA5A5_00FF, 32'h0000_0000, 32'h1234_5678,
                     1'b1);

    // 4. SEUs simultáneos en r0 y r1 en bits DISTINTOS -> votación bit a bit sigue recuperando el dato
    inject_and_check(32'hDEAD_BEEF, 32'h0000_000F, 32'h000F_0000, 32'h0000_0000, 32'hDEAD_BEEF,
                     1'b1);

    // 5. Caso límite (2 copias alteradas en el MISMO bit): la mayoría 2-de-3 vota el bit erróneo
    //    (Demuestra por qué necesitamos self-healing en el siguiente ciclo antes de un 2º impacto)
    inject_and_check(32'hDEAD_BEEF, 32'h0000_0004, 32'h0000_0004, 32'h0000_0000, 32'hDEAD_BEEB,
                     1'b1);

    if (errors == 0) $display("\n[OK] Todos los tests de tmr_voter superados.");
    else $display("\n[ERROR] %0d tests fallidos.", errors);

    $finish;
  end

endmodule
