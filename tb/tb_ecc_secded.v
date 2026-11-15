// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       tb_ecc_secded.v
// Descripción:  Testbench exhaustivo SBE/DBE para Hsiao SEC-DED (39,32)
// Reloj/Reset:  Sin reloj (estímulos combinacionales con inyección XOR)
// =============================================================================

`timescale 1ns / 1ps

module tb_ecc_secded;

  reg     [31:0] tx_data;
  reg     [38:0] err_mask;
  wire    [38:0] tx_encoded;
  wire    [38:0] rx_encoded;
  wire    [31:0] rx_data;
  wire    [ 6:0] rx_ecc;
  wire           sbiterr;
  wire           dbiterr;

  integer        errors;
  integer        checks;

  ecc_secded_enc u_enc (
      .data_i   (tx_data),
      .encoded_o(tx_encoded)
  );

  // Canal con inyección de fallos por radiación (máscara XOR de 39 bits)
  assign rx_encoded = tx_encoded ^ err_mask;

  ecc_secded_dec u_dec (
      .encoded_i(rx_encoded),
      .data_o   (rx_data),
      .ecc_o    (rx_ecc),
      .sbiterr_o(sbiterr),
      .dbiterr_o(dbiterr)
  );

  task test_word(input [31:0] val);
    integer i;
    integer j;
    reg [6:0] expected_ecc;
    begin
      // 1. Estado nominal (sin error)
      tx_data  = val;
      err_mask = 39'd0;
      #1;  // Propagación combinacional (delta + 1 ns) antes de muestrear
      expected_ecc = tx_encoded[38:32];
      checks = checks + 1;

      if (rx_data !== val || rx_ecc !== expected_ecc || sbiterr !== 1'b0 || dbiterr !== 1'b0) begin
        $display("[FAIL NOM @ %0t ns] val=%h | rx=%h ecc=%b (esp %b) s=%b d=%b", $time, val,
                 rx_data, rx_ecc, expected_ecc, sbiterr, dbiterr);
        errors = errors + 1;
      end
      #9;

      // 2. Todos los 39 errores simples (datos [31:0] + paridad [38:32])
      for (i = 0; i < 39; i = i + 1) begin
        err_mask = (39'd1 << i);
        #1;
        checks = checks + 1;
        if (rx_data !== val || rx_ecc !== expected_ecc || sbiterr !== 1'b1 || dbiterr !== 1'b0) begin
          $display("[FAIL SBE bit=%0d @ %0t ns] val=%h | rx=%h ecc=%b s=%b d=%b", i, $time, val,
                   rx_data, rx_ecc, sbiterr, dbiterr);
          errors = errors + 1;
        end
        #9;
      end

      // 3. Todos los 741 errores dobles posibles sobre los 39 bits
      for (i = 0; i < 39; i = i + 1) begin
        for (j = i + 1; j < 39; j = j + 1) begin
          err_mask = (39'd1 << i) | (39'd1 << j);
          #1;
          checks = checks + 1;
          if (sbiterr !== 1'b0 || dbiterr !== 1'b1) begin
            $display("[FAIL DBE (%0d,%0d) @ %0t ns] val=%h | s=%b d=%b", i, j, $time, val, sbiterr,
                     dbiterr);
            errors = errors + 1;
          end
          #9;
        end
      end

      $display("[PASS] Patron 0x%h verificado (1 nominal + 39 SBE + 741 DBE)", val);
    end
  endtask

  initial begin
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_ecc_secded);

    errors   = 0;
    checks   = 0;
    tx_data  = 32'h0000_0000;
    err_mask = 39'd0;
    #1;

    // Verificación explícita de que todo-ceros tiene palabra código 39'h0
    checks = checks + 1;
    if (tx_encoded !== 39'd0) begin
      $display("[FAIL RESET-ZERO] encoded(0) = %h (esperado 0)", tx_encoded);
      errors = errors + 1;
    end else begin
      $display("[PASS] Palabra nula 32'h00000000 -> palabra codigo 39'h0");
    end
    #9;

    test_word(32'h0000_0000);
    test_word(32'hFFFF_FFFF);
    test_word(32'hAAAA_AAAA);
    test_word(32'h5555_5555);
    test_word(32'hCAFE_BABE);
    test_word(32'h1234_5678);
    test_word(32'hDEAD_BEEF);

    if (errors == 0)
      $display("\n[OK] Hsiao (39,32): %0d/%0d comprobaciones superadas.", checks, checks);
    else $display("\n[ERROR] %0d de %0d comprobaciones fallidas.", errors, checks);

    $finish;
  end

endmodule
