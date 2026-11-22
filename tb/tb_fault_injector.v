// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       tb_fault_injector.v
// Descripción:  Testbench unitario para fault_injector (dirigido, timeout y LFSR)
// Reloj/Reset:  clk simulado a 100 MHz | resetn síncrono activo bajo
// =============================================================================

`timescale 1ns / 1ps

module tb_fault_injector;

  reg clk = 1'b1;
  always #5 clk = ~clk;  // 100 MHz

  reg            resetn;
  reg            enable_i;
  reg            auto_mode_i;
  reg            soc_profile_i;
  reg            reg_ecc_en_i;
  reg            dbe_mode_i;
  reg            trig_i;
  reg            seed_load_i;
  reg     [31:0] seed_i;
  reg     [ 3:0] cfg_target_i;
  reg     [ 2:0] cfg_rep_mask_i;
  reg     [38:0] cfg_bit_mask_i;
  reg     [31:0] interval_i;
  reg     [15:0] max_faults_i;

  wire           fi_valid_o;
  wire    [ 3:0] fi_target_o;
  wire    [ 2:0] fi_rep_mask_o;
  wire    [38:0] fi_bit_mask_o;
  reg            auto_ack_imm;
  reg            manual_ack;
  wire           fi_ack_i = auto_ack_imm ? fi_valid_o : manual_ack;
  wire    [31:0] inj_count_o;
  wire           fi_timeout_o;

  integer        errors = 0;

  fault_injector #(
      .DEFAULT_SEED(32'hACE1_1357),
      .ACK_TIMEOUT (32'd20)
  ) uut (
      .clk           (clk),
      .resetn        (resetn),
      .enable_i      (enable_i),
      .auto_mode_i   (auto_mode_i),
      .soc_profile_i (soc_profile_i),
      .reg_ecc_en_i  (reg_ecc_en_i),
      .dbe_mode_i    (dbe_mode_i),
      .trig_i        (trig_i),
      .seed_load_i   (seed_load_i),
      .seed_i        (seed_i),
      .cfg_target_i  (cfg_target_i),
      .cfg_rep_mask_i(cfg_rep_mask_i),
      .cfg_bit_mask_i(cfg_bit_mask_i),
      .interval_i    (interval_i),
      .max_faults_i  (max_faults_i),
      .fi_valid_o    (fi_valid_o),
      .fi_target_o   (fi_target_o),
      .fi_rep_mask_o (fi_rep_mask_o),
      .fi_bit_mask_o (fi_bit_mask_o),
      .fi_ack_i      (fi_ack_i),
      .inj_count_o   (inj_count_o),
      .fi_timeout_o  (fi_timeout_o)
  );

  // Cuenta bits a 1 en una máscara de 39b (para verificar que SBE=1 bit y DBE=2 bits)
  function integer popcount39;
    input [38:0] vec;
    integer k;
    begin
      popcount39 = 0;
      for (k = 0; k < 39; k = k + 1) popcount39 = popcount39 + vec[k];
    end
  endfunction

  // Cuenta cuántas réplicas TMR (de 0 a 3) selecciona fi_rep_mask_o
  function integer popcount3;
    input [2:0] vec;
    begin
      popcount3 = vec[0] + vec[1] + vec[2];
    end
  endfunction

  // Devuelve los bits que realmente existen en cada módulo destino (para detectar bits fuera de rango)
  function [38:0] legal_mask;
    input [3:0] tgt;
    input ecc_en;
    begin
      case (tgt)
        4'd0, 4'd1: legal_mask = 39'h00_FFFF_FFFF;
        4'd2:       legal_mask = 39'h00_0000_00FF;
        4'd3:       legal_mask = 39'h00_0000_0003;
        4'd4:       legal_mask = 39'h00_0000_001F;
        4'd5:       legal_mask = ecc_en ? 39'h7F_FFFF_FFFF : 39'h00_FFFF_FFFF;
        default:    legal_mask = 39'h7F_FFFF_FFFF;
      endcase
    end
  endfunction

  task apply_reset;
    begin
      resetn         = 1'b0;
      enable_i       = 1'b0;
      auto_mode_i    = 1'b0;
      soc_profile_i  = 1'b0;
      reg_ecc_en_i   = 1'b1;
      dbe_mode_i     = 1'b0;
      trig_i         = 1'b0;
      seed_load_i    = 1'b0;
      seed_i         = 32'h0;
      cfg_target_i   = 4'd0;
      cfg_rep_mask_i = 3'd0;
      cfg_bit_mask_i = 39'd0;
      interval_i     = 32'd1;
      max_faults_i   = 16'd0;
      auto_ack_imm   = 1'b0;
      manual_ack     = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      resetn = 1'b1;
    end
  endtask

  // Almacenamiento de historial para comprobar determinismo bit a bit por semilla
  reg     [ 3:0] hist_tgt  [0:9];
  reg     [ 2:0] hist_rep  [0:9];
  reg     [38:0] hist_mask [0:9];
  reg     [ 7:0] seen_tgt;
  integer        cap_idx;
  reg     [31:0] cnt_start;

  // Ejecuta una campaña autónoma LFSR y valida cada inyección armada en fi_valid_o
  task run_auto_campaign;
    input [31:0] seed_val;
    input soc_prof;
    input ecc_en;
    input dbe_en;
    input [31:0] inter;
    input [15:0] budget;
    input integer wait_cycles;
    input integer check_hist;  // 0: sin historial | 1: grabar | 2: comparar
    integer exp_reps;
    integer exp_bits;
    begin
      @(negedge clk);
      auto_ack_imm  = 1'b1;
      soc_profile_i = soc_prof;
      reg_ecc_en_i  = ecc_en;
      dbe_mode_i    = dbe_en;
      interval_i    = inter;
      max_faults_i  = budget;
      auto_mode_i   = 1'b1;
      enable_i      = 1'b0;
      seed_i        = seed_val;
      seed_load_i   = 1'b1;
      @(posedge clk);

      @(negedge clk);
      seed_load_i = 1'b0;
      enable_i    = 1'b1;
      cnt_start   = inj_count_o;
      seen_tgt    = 8'h00;
      cap_idx     = 0;

      repeat (wait_cycles) begin
        @(posedge clk);
        #1;
        if (fi_valid_o === 1'b1) begin
          if (!soc_prof && (fi_target_o > 4'd5)) begin
            $display("[FAIL AUTO] Objetivo %0d fuera de perfil CPU-only", fi_target_o);
            errors = errors + 1;
          end

          if ((fi_bit_mask_o & ~legal_mask(fi_target_o, ecc_en)) !== 39'd0) begin
            $display("[FAIL AUTO] Mascara %h fuera de ancho para tgt=%0d (ecc=%b)", fi_bit_mask_o,
                     fi_target_o, ecc_en);
            errors = errors + 1;
          end

          exp_reps = (fi_target_o <= 4'd4) ? (dbe_en ? 2 : 1) : 1;
          exp_bits = (fi_target_o <= 4'd4) ? 1 : (dbe_en ? 2 : 1);

          if (popcount3(fi_rep_mask_o) !== exp_reps || popcount39(fi_bit_mask_o) !== exp_bits) begin
            $display("[FAIL AUTO] Cardinalidad errónea tgt=%0d rep=%b mask=%h", fi_target_o,
                     fi_rep_mask_o, fi_bit_mask_o);
            errors = errors + 1;
          end

          seen_tgt[fi_target_o[2:0]] = 1'b1;

          if (check_hist == 1 && cap_idx < 10) begin
            hist_tgt[cap_idx]  = fi_target_o;
            hist_rep[cap_idx]  = fi_rep_mask_o;
            hist_mask[cap_idx] = fi_bit_mask_o;
          end else if (check_hist == 2 && cap_idx < 10) begin
            if (fi_target_o !== hist_tgt[cap_idx] ||
                fi_rep_mask_o !== hist_rep[cap_idx] ||
                fi_bit_mask_o !== hist_mask[cap_idx]) begin
              $display("[FAIL DET] Fallo %0d difiere con la misma semilla", cap_idx);
              errors = errors + 1;
            end
          end
          cap_idx = cap_idx + 1;
        end
      end

      if ((inj_count_o - cnt_start) !== {16'd0, budget}) begin
        $display("[FAIL BUDGET] Consumidos %0d (esperado %0d)", inj_count_o - cnt_start, budget);
        errors = errors + 1;
      end

      @(negedge clk);
      enable_i     = 1'b0;
      auto_mode_i  = 1'b0;
      auto_ack_imm = 1'b0;
      @(posedge clk);  // Limpia auto_sent_q antes de la siguiente campaña
    end
  endtask

  initial begin
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_fault_injector);

    // T1: Reset limpio + protección contra semilla 0 (si seed=0 debe cargar DEFAULT_SEED)
    apply_reset;
    if (fi_valid_o !== 1'b0 || inj_count_o !== 32'd0 || fi_timeout_o !== 1'b0) begin
      $display("[FAIL T1a] Estado inicial tras reset incorrecto");
      errors = errors + 1;
    end
    seed_i      = 32'h0000_0000;
    seed_load_i = 1'b1;
    @(posedge clk);
    #1;
    if (uut.lfsr_q !== 32'hACE1_1357) begin
      $display("[FAIL T1b] Semilla nula no cargo DEFAULT_SEED (lfsr=%h)", uut.lfsr_q);
      errors = errors + 1;
    end else $display("[PASS] T1: Reset y proteccion de semilla nula");
    @(negedge clk);
    seed_load_i    = 1'b0;

    // T2: Disparo dirigido con pulso largo (3 ciclos) -> debe disparar 1 sola vez por flanco
    auto_ack_imm   = 1'b1;
    cfg_target_i   = 4'd0;
    cfg_rep_mask_i = 3'b010;
    cfg_bit_mask_i = 39'h00_0000_0004;
    trig_i         = 1'b1;
    @(posedge clk);  // Flanco 1: detecta trig_pulse y arma ST_ARMED
    #1;
    if (fi_valid_o !== 1'b1 || fi_target_o !== 4'd0 ||
        fi_rep_mask_o !== 3'b010 || fi_bit_mask_o !== 39'h00_0000_0004) begin
      $display("[FAIL T2a] Fallo al armar disparo dirigido");
      errors = errors + 1;
    end
    @(posedge clk);  // Flanco 2: consume ack inmediato, vuelve a ST_IDLE
    #1;
    if (fi_valid_o !== 1'b0 || inj_count_o !== 32'd1) begin
      $display("[FAIL T2b] No desarmo en 1 ciclo (valid=%b cnt=%0d)", fi_valid_o, inj_count_o);
      errors = errors + 1;
    end
    repeat (2) @(posedge clk);  // trig_i sigue alto: no debe re-disparar
    #1;
    if (inj_count_o !== 32'd1) begin
      $display("[FAIL T2c] Detector de flanco re-disparo con trig_i sostenido (cnt=%0d)",
               inj_count_o);
      errors = errors + 1;
    end else $display("[PASS] T2: Disparo dirigido + ack inmediato + detector de flanco");
    @(negedge clk);
    trig_i       = 1'b0;
    auto_ack_imm = 1'b0;

    // T3: Handshake con ack diferido (simula espera hasta que DMEM/cpuregs realice un acceso)
    @(negedge clk);
    cfg_target_i   = 4'd7;
    cfg_rep_mask_i = 3'b001;
    cfg_bit_mask_i = 39'h00_0000_0003;
    trig_i         = 1'b1;
    @(posedge clk);
    @(negedge clk);
    trig_i = 1'b0;
    repeat (8) begin
      @(posedge clk);
      #1;
      if (fi_valid_o !== 1'b1 || inj_count_o !== 32'd1) begin
        $display("[FAIL T3a] Solicitud cayo antes de recibir ack");
        errors = errors + 1;
      end
    end
    @(negedge clk);
    manual_ack = 1'b1;
    @(posedge clk);
    #1;
    if (fi_valid_o !== 1'b0 || inj_count_o !== 32'd2) begin
      $display("[FAIL T3b] No libero tras ack diferido (valid=%b cnt=%0d)", fi_valid_o,
               inj_count_o);
      errors = errors + 1;
    end else $display("[PASS] T3: Handshake armado diferido (8 ciclos)");
    @(negedge clk);
    manual_ack = 1'b0;

    // T4: Expiracion por ACK_TIMEOUT = 20 ciclos sin ack
    @(negedge clk);
    cfg_target_i   = 4'd6;
    cfg_bit_mask_i = 39'h00_0000_0010;
    trig_i         = 1'b1;
    @(posedge clk);
    @(negedge clk);
    trig_i = 1'b0;
    repeat (19) @(posedge clk);  // Ciclos 1..19 esperando
    #1;
    if (fi_valid_o !== 1'b1 || fi_timeout_o !== 1'b0) begin
      $display("[FAIL T4a] Timeout prematuro");
      errors = errors + 1;
    end
    @(posedge clk);  // Ciclo 20: timer_q == 19 == TIMEOUT_LIM -> expira
    #1;
    if (fi_valid_o !== 1'b0 || fi_timeout_o !== 1'b1 || inj_count_o !== 32'd2) begin
      $display("[FAIL T4b] Timeout no disparo al ciclo 20 (valid=%b to=%b cnt=%0d)", fi_valid_o,
               fi_timeout_o, inj_count_o);
      errors = errors + 1;
    end
    @(posedge clk);
    #1;
    if (fi_timeout_o !== 1'b0) begin
      $display("[FAIL T4c] fi_timeout_o debe durar solo 1 ciclo");
      errors = errors + 1;
    end else $display("[PASS] T4: ACK_TIMEOUT de 20 ciclos y pulso de 1 ciclo");

    // T5: Presupuesto 1-SEU, 10-SEU estilo HARV y determinismo exacto por semilla
    run_auto_campaign(32'h1234_5678, 1'b0, 1'b1, 1'b0, 32'd5, 16'd1, 40, 0);
    $display("[PASS] T5a: Campana autonoma 1-SEU (presupuesto exacto = 1)");

    run_auto_campaign(32'hCAFE_BABE, 1'b0, 1'b1, 1'b0, 32'd5, 16'd10, 200, 1);
    run_auto_campaign(32'hCAFE_BABE, 1'b0, 1'b1, 1'b0, 32'd5, 16'd10, 200, 2);
    $display("[PASS] T5b: Campana 10-SEU determinista y reproducible por semilla");

    // T6: Modo DBE/MBU en SoC completo (0..7, 39b) y en CPU-only sin ECC (0..5, 32b)
    run_auto_campaign(32'hDEAD_BEEF, 1'b1, 1'b1, 1'b1, 32'd1, 16'd160, 1600, 0);
    if (seen_tgt !== 8'hFF) begin
      $display("[FAIL T6a] No cubrio todos los objetivos 0..7 (seen=%b)", seen_tgt);
      errors = errors + 1;
    end else $display("[PASS] T6a: Modo DBE/MBU cubrio los 8 objetivos con anchos validos");

    run_auto_campaign(32'h55AA_33CC, 1'b0, 1'b0, 1'b1, 32'd1, 16'd120, 1200, 0);
    if (seen_tgt !== 8'h3F) begin
      $display("[FAIL T6b] Perfil CPU-only deberia cubrir exactamente 0..5 (seen=%b)", seen_tgt);
      errors = errors + 1;
    end else $display("[PASS] T6b: Perfil CPU-only sin ECC acotado a 0..5 y 32 bits");

    if (errors == 0) $display("\n[OK] Todos los tests de fault_injector superados.");
    else $display("\n[ERROR] %0d tests fallidos.", errors);
    $finish;
  end

endmodule
