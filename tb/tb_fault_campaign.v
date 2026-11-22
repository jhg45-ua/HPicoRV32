// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       tb_fault_campaign.v
// Descripción:  Banco de campaña estadística HARV (Golden, 1/10-SEU y DBE/W^X)
// Reloj/Reset:  clk (100 MHz) | resetn (activo bajo por corrida)
// =============================================================================

`timescale 1 ns / 1 ps

module tb_fault_campaign #(
    parameter [0:0] ENABLE_TMR     = 1'b1,
    parameter [0:0] ENABLE_REG_ECC = 1'b1,
    parameter [0:0] RUN_BASELINE   = 1'b1
);

`ifdef VERILATOR
  localparam integer DEFAULT_NUM_RUNS = 1000;
`else
  localparam integer DEFAULT_NUM_RUNS = 100;
`endif

  reg clk = 1'b0;
  always #5 clk = ~clk;

  // Selector entre DUT principal (u_soc) y referencia sin endurecimiento (u_base)
  reg         active_base = 1'b0;
  reg         dut_resetn  = 1'b0;
  wire        soc_resetn  = !active_base && dut_resetn;
  wire        base_resetn = active_base && dut_resetn;

  reg         inj_resetn     = 1'b0;
  reg         fi_enable      = 1'b0;
  reg         fi_auto_mode   = 1'b1;
  reg         fi_soc_profile = 1'b1;
  reg         fi_dbe_mode    = 1'b0;
  reg         fi_trig        = 1'b0;
  reg         fi_seed_load   = 1'b0;
  reg  [31:0] fi_seed        = 32'h0;
  reg  [ 3:0] fi_cfg_target  = 4'd0;
  reg  [ 2:0] fi_cfg_rep     = 3'd0;
  reg  [38:0] fi_cfg_mask    = 39'd0;
  reg  [31:0] fi_interval    = 32'd100;
  reg  [15:0] fi_max_faults  = 16'd1;

  wire        fi_valid;
  wire [ 3:0] fi_target;
  wire [ 2:0] fi_rep_mask;
  wire [38:0] fi_bit_mask;
  wire        soc_fi_ack;
  wire        base_fi_ack;
  wire        fi_ack_mux     = active_base ? base_fi_ack : soc_fi_ack;
  wire [31:0] fi_inj_count;
  wire        fi_timeout;
  wire        fi_reg_ecc_cfg = active_base ? 1'b0 : ENABLE_REG_ECC;

  fault_injector #(
      .ACK_TIMEOUT(32'd200000)
  ) u_inj (
      .clk           (clk),
      .resetn        (inj_resetn),
      .enable_i      (fi_enable),
      .auto_mode_i   (fi_auto_mode),
      .soc_profile_i (fi_soc_profile),
      .reg_ecc_en_i  (fi_reg_ecc_cfg),
      .dbe_mode_i    (fi_dbe_mode),
      .trig_i        (fi_trig),
      .seed_load_i   (fi_seed_load),
      .seed_i        (fi_seed),
      .cfg_target_i  (fi_cfg_target),
      .cfg_rep_mask_i(fi_cfg_rep),
      .cfg_bit_mask_i(fi_cfg_mask),
      .interval_i    (fi_interval),
      .max_faults_i  (fi_max_faults),
      .fi_valid_o    (fi_valid),
      .fi_target_o   (fi_target),
      .fi_rep_mask_o (fi_rep_mask),
      .fi_bit_mask_o (fi_bit_mask),
      .fi_ack_i      (fi_ack_mux),
      .inj_count_o   (fi_inj_count),
      .fi_timeout_o  (fi_timeout)
  );

  // DUT principal
  wire        soc_trap;
  wire [14:0] soc_leds;
  wire        soc_ser_tx;

  soc_core #(
      .IMEM_WORDS    (2048),
      .DMEM_WORDS    (2048),
      .ENABLE_TMR    (ENABLE_TMR),
      .ENABLE_REG_ECC(ENABLE_REG_ECC),
      .FIRMWARE_FILE ("build/firmware.hex"),
      .ENABLE_FI     (1'b1)
  ) u_soc (
      .clk          (clk),
      .resetn       (soc_resetn),
      .trap         (soc_trap),
      .leds         (soc_leds),
      .ser_tx       (soc_ser_tx),
      .ser_rx       (1'b1),
      .fi_valid_i   (fi_valid && !active_base),
      .fi_target_i  (fi_target),
      .fi_rep_mask_i(fi_rep_mask),
      .fi_bit_mask_i(fi_bit_mask),
      .fi_ack_o     (soc_fi_ack)
  );

  // DUT de referencia sin endurecimiento (ENABLE_TMR=0, ENABLE_REG_ECC=0)
  wire        base_trap;
  wire [14:0] base_leds;
  wire        base_ser_tx;

  soc_core #(
      .IMEM_WORDS    (2048),
      .DMEM_WORDS    (2048),
      .ENABLE_TMR    (1'b0),
      .ENABLE_REG_ECC(1'b0),
      .FIRMWARE_FILE ("build/firmware.hex"),
      .ENABLE_FI     (1'b1)
  ) u_base (
      .clk          (clk),
      .resetn       (base_resetn),
      .trap         (base_trap),
      .leds         (base_leds),
      .ser_tx       (base_ser_tx),
      .ser_rx       (1'b1),
      .fi_valid_i   (fi_valid && active_base),
      .fi_target_i  (fi_target),
      .fi_rep_mask_i(fi_rep_mask),
      .fi_bit_mask_i(fi_bit_mask),
      .fi_ack_o     (base_fi_ack)
  );

  wire        active_trap   = active_base ? base_trap : soc_trap;
  wire [14:0] active_leds   = active_base ? base_leds : soc_leds;
  wire        active_ser_tx = active_base ? base_ser_tx : soc_ser_tx;

  // Variables de golden run, receptor UART y clasificador
  integer     num_runs;
  integer     base_runs;
  integer     golden_cycles;
  integer     golden_compute_cycles;
  reg  [31:0] golden_result;

  reg  [31:0] tb_lfsr;
  reg  [31:0] rx_result;
  reg  [31:0] rx_pc_err;
  reg  [31:0] rx_ctrl_err;
  reg  [31:0] rx_reg_sbu;
  reg  [31:0] rx_reg_dbu;
  reg  [31:0] rx_imem_sbu;
  reg  [31:0] rx_imem_dbu;
  reg  [31:0] rx_dmem_sbu;
  reg  [31:0] rx_dmem_dbu;
  reg         got_result;
  reg         got_telem;

  // Estado interno del receptor serie y parser por corrida
  reg  [ 3:0] urx_state;
  integer     urx_cnt;
  reg  [ 7:0] urx_shift;
  integer     uart_bit_clks;
  reg  [31:0] key4;
  reg         hex_en;
  reg  [ 3:0] hex_fld;
  reg  [ 3:0] hex_cnt;
  reg  [31:0] hex_acc;

  // Salidas de run_once
  reg         run_done;
  reg         run_trap;
  reg         run_timeout;
  reg         run_cpu_trap;
  reg         run_harv_fault;
  reg         run_ecc_fault;
  reg  [31:0] run_reg_dbu_hw;
  reg  [31:0] run_imem_dbu_hw;
  reg  [31:0] run_dmem_dbu_hw;
  integer     run_cycles;
  integer     run_comp_start;
  integer     run_comp_end;
  integer     run_inj_delta;
  integer     run_inj_timeouts;

  integer     total_failures = 0;

  function automatic [31:0] lfsr32_next(input [31:0] s);
    reg fb;
    begin
      fb = s[31] ^ s[21] ^ s[1] ^ s[0];
      lfsr32_next = {s[30:0], fb};
    end
  endfunction

  task automatic parse_uart_char(input [7:0] ch);
    reg       is_hex;
    reg [3:0] nib;
    begin
      is_hex = 1'b0;
      nib    = 4'd0;
      if (ch >= "0" && ch <= "9") begin
        is_hex = 1'b1;
        nib    = ch[3:0];
      end else if (ch >= "A" && ch <= "F") begin
        is_hex = 1'b1;
        nib    = (ch - 8'h41) + 4'd10;
      end else if (ch >= "a" && ch <= "f") begin
        is_hex = 1'b1;
        nib    = (ch - 8'h61) + 4'd10;
      end

      if (hex_en) begin
        if ((ch == "x" || ch == "X") && (hex_fld == 4'd0) && (hex_cnt <= 4'd1)) begin
          // Descarta prefijo "0x" de RESULT=0xXXXXXXXX
          hex_cnt = 4'd0;
          hex_acc = 32'h0;
        end else if (is_hex) begin
          hex_acc = {hex_acc[27:0], nib};
          hex_cnt = hex_cnt + 4'd1;
          if (hex_cnt == 4'd8) begin
            case (hex_fld)
              4'd0: begin rx_result   = hex_acc; got_result = 1'b1; end
              4'd1: rx_pc_err   = hex_acc;
              4'd2: rx_ctrl_err = hex_acc;
              4'd3: rx_reg_sbu  = hex_acc;
              4'd4: rx_reg_dbu  = hex_acc;
              4'd5: rx_imem_sbu = hex_acc;
              4'd6: rx_imem_dbu = hex_acc;
              4'd7: rx_dmem_sbu = hex_acc;
              4'd8: begin rx_dmem_dbu = hex_acc; got_telem  = 1'b1; end
              default: ;
            endcase
            hex_en  = 1'b0;
            hex_cnt = 4'd0;
          end
        end else begin
          hex_en  = 1'b0;
          hex_cnt = 4'd0;
        end
      end else if (ch == "=") begin
        hex_cnt = 4'd0;
        hex_acc = 32'h0;
        if (key4[23:0] == "ULT") begin
          hex_en  = 1'b1;
          hex_fld = 4'd0;
        end else if (key4[23:0] == " PC") begin
          hex_en  = 1'b1;
          hex_fld = 4'd1;
        end else if (key4 == "CTRL") begin
          hex_en  = 1'b1;
          hex_fld = 4'd2;
        end else if (key4 == " SBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd3;
        end else if (key4 == " DBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd4;
        end else if (key4 == "ISBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd5;
        end else if (key4 == "IDBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd6;
        end else if (key4 == "DSBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd7;
        end else if (key4 == "DDBU") begin
          hex_en  = 1'b1;
          hex_fld = 4'd8;
        end
      end

      key4 = {key4[23:0], ch};
    end
  endtask

  task automatic step_uart_rx;
    begin
      case (urx_state)
        4'd0: begin
          if (active_ser_tx == 1'b0) begin
            urx_state = 4'd1;
            urx_cnt   = 1;
          end
        end
        4'd1: begin
          if (urx_cnt >= (uart_bit_clks / 2)) begin
            if (active_ser_tx == 1'b0) begin
              urx_state = 4'd2;
              urx_cnt   = 0;
              urx_shift = 8'h0;
            end else begin
              urx_state = 4'd0;
            end
          end else begin
            urx_cnt = urx_cnt + 1;
          end
        end
        4'd10: begin
          if (urx_cnt >= (uart_bit_clks - 1)) begin
            if (active_ser_tx == 1'b1) begin
              parse_uart_char(urx_shift);
            end
            urx_state = 4'd0;
          end else begin
            urx_cnt = urx_cnt + 1;
          end
        end
        default: begin
          if (urx_cnt >= (uart_bit_clks - 1)) begin
            urx_shift = {active_ser_tx, urx_shift[7:1]};
            urx_state = urx_state + 4'd1;
            urx_cnt   = 0;
          end else begin
            urx_cnt = urx_cnt + 1;
          end
        end
      endcase
    end
  endtask

  task automatic load_inj_seed(input [31:0] seed_val);
    begin
      fi_enable    = 1'b0;
      fi_trig      = 1'b0;
      fi_seed      = seed_val;
      fi_seed_load = 1'b1;
      @(negedge clk);
      fi_seed_load = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic run_once(
      input        use_base,
      input        enable_faults,
      input        auto_mode,
      input        soc_prof,
      input        dbe_en,
      input [31:0] start_delay,
      input [31:0] interval_cyc,
      input [15:0] max_faults,
      input [ 3:0] dir_tgt,
      input [ 2:0] dir_rep,
      input [38:0] dir_mask,
      input [14:0] trig_leds_min,
      input integer max_cycles
  );
    reg [31:0] inj_start;
    reg        started_comp;
    reg        ended_comp;
    reg        armed_fi;
    reg        finished;
    integer    extra;
    begin
      dut_resetn     = 1'b0;
      active_base    = use_base;
      fi_enable      = 1'b0;
      fi_trig        = 1'b0;
      fi_auto_mode   = auto_mode;
      fi_soc_profile = soc_prof;
      fi_dbe_mode    = dbe_en;
      fi_interval    = interval_cyc;
      fi_max_faults  = max_faults;
      fi_cfg_target  = dir_tgt;
      fi_cfg_rep     = dir_rep;
      fi_cfg_mask    = dir_mask;

      rx_result      = 32'h0;
      rx_pc_err      = 32'h0;
      rx_ctrl_err    = 32'h0;
      rx_reg_sbu     = 32'h0;
      rx_reg_dbu     = 32'h0;
      rx_imem_sbu    = 32'h0;
      rx_imem_dbu    = 32'h0;
      rx_dmem_sbu    = 32'h0;
      rx_dmem_dbu    = 32'h0;
      got_result     = 1'b0;
      got_telem      = 1'b0;

      urx_state      = 4'd0;
      urx_cnt        = 0;
      urx_shift      = 8'h0;
      uart_bit_clks  = 18;
      key4           = 32'h0;
      hex_en         = 1'b0;
      hex_fld        = 4'd0;
      hex_cnt        = 4'd0;
      hex_acc        = 32'h0;

      run_done         = 1'b0;
      run_trap         = 1'b0;
      run_timeout      = 1'b0;
      run_cpu_trap     = 1'b0;
      run_harv_fault   = 1'b0;
      run_ecc_fault    = 1'b0;
      run_reg_dbu_hw   = 32'd0;
      run_imem_dbu_hw  = 32'd0;
      run_dmem_dbu_hw  = 32'd0;
      run_cycles       = 0;
      run_comp_start   = 0;
      run_comp_end     = 0;
      run_inj_timeouts = 0;

      repeat (10) @(negedge clk);
      inj_start  = fi_inj_count;
      dut_resetn = 1'b1;

      started_comp = 1'b0;
      ended_comp   = 1'b0;
      armed_fi     = 1'b0;
      finished     = 1'b0;

      while (!finished) begin
        @(negedge clk);
        run_cycles = run_cycles + 1;
        if (fi_timeout) run_inj_timeouts = run_inj_timeouts + 1;

        if (!started_comp && (active_leds != 15'd0)) begin
          started_comp   = 1'b1;
          run_comp_start = run_cycles;
          uart_bit_clks  = (use_base ? u_base.uart.cfg_divider : u_soc.uart.cfg_divider) + 32'd2;
        end

        if (!ended_comp && ((active_leds == 15'h0004) || (active_leds == 15'h7FFF))) begin
          ended_comp   = 1'b1;
          run_comp_end = run_cycles;
          fi_enable    = 1'b0;
        end

        // Habilita inyección dentro de la ventana activa de cómputo
        fi_trig = 1'b0;
        if (enable_faults && !armed_fi && !ended_comp &&
            (active_leds >= trig_leds_min) && started_comp &&
            (run_cycles >= (run_comp_start + start_delay))) begin
          armed_fi = 1'b1;
          if (auto_mode) begin
            fi_enable = 1'b1;
          end else begin
            fi_trig = 1'b1;
          end
        end

        if (started_comp) step_uart_rx;

        if (active_trap) begin
          run_trap  = 1'b1;
          fi_enable = 1'b0;
          for (extra = 0; extra < 4; extra = extra + 1) @(negedge clk);
          finished = 1'b1;
        end else if ((active_leds == 15'h7FFF) && got_result && got_telem) begin
          run_done  = 1'b1;
          fi_enable = 1'b0;
          finished  = 1'b1;
        end else if (run_cycles >= max_cycles) begin
          run_timeout = 1'b1;
          fi_enable   = 1'b0;
          finished    = 1'b1;
        end
      end

      fi_enable       = 1'b0;
      fi_trig         = 1'b0;
      run_inj_delta   = fi_inj_count - inj_start;
      run_cpu_trap    = u_soc.cpu_trap;
      run_harv_fault  = u_soc.harv_fault_r;
      run_ecc_fault   = u_soc.ecc_fault_r;
      run_reg_dbu_hw  = u_soc.cpu.count_ecc_reg_dbu;
      run_imem_dbu_hw = u_soc.count_ecc_imem_dbu;
      run_dmem_dbu_hw = u_soc.count_ecc_dmem_dbu;
      dut_resetn      = 1'b0;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic run_auto_campaign(
      input [8*32-1:0] label,
      input            use_base,
      input            soc_prof,
      input            multi_seu,
      input integer    n_runs,
      input [31:0]     camp_seed,
      input            expect_zero_sdc
  );
    integer r;
    integer match_cnt;
    integer corr_cnt;
    integer latent_cnt;
    integer sdc_cnt;
    integer hang_cnt;
    integer inj_sum;
    integer zero_inj_cnt;
    integer compute_span;
    integer span_mod;
    reg [31:0] ivl;
    reg [31:0] dly;
    reg [15:0] max_f;
    integer tot_telem;
    integer tot_dbu;
    begin
      match_cnt    = 0;
      corr_cnt     = 0;
      latent_cnt   = 0;
      sdc_cnt      = 0;
      hang_cnt     = 0;
      inj_sum      = 0;
      zero_inj_cnt = 0;

      // Sincroniza semilla LFSR y generador de instantes de prueba para reproducibilidad A/B
      tb_lfsr = camp_seed ^ 32'h5A5A_1234;
      load_inj_seed(camp_seed);

      compute_span = (golden_compute_cycles * 65) / 100;
      if (compute_span < 100) compute_span = 100;

      for (r = 0; r < n_runs; r = r + 1) begin
        tb_lfsr = lfsr32_next(tb_lfsr);
        if (multi_seu) begin
          span_mod = golden_compute_cycles / 20;
          if (span_mod < 20) span_mod = 20;
          dly   = (tb_lfsr & 32'h7FFFFFFF) % span_mod;
          ivl   = (golden_compute_cycles * 5) / 100;
          if (ivl < 32'd20) ivl = 32'd20;
          max_f = 16'd10;
        end else begin
          dly   = 32'd0;
          ivl   = 32'd4 + ((tb_lfsr & 32'h7FFFFFFF) % compute_span);
          max_f = 16'd1;
        end

        run_once(
            use_base,
            1'b1,
            1'b1,
            soc_prof,
            1'b0,
            dly,
            ivl,
            max_f,
            4'd0,
            3'd0,
            39'd0,
            15'h0001,
            golden_cycles * 2
        );

        inj_sum = inj_sum + run_inj_delta;
        if (run_inj_delta == 0) zero_inj_cnt = zero_inj_cnt + 1;

        if (!run_done || run_trap || run_timeout) begin
          hang_cnt = hang_cnt + 1;
        end else if (rx_result !== golden_result) begin
          sdc_cnt = sdc_cnt + 1;
        end else begin
          match_cnt = match_cnt + 1;
          tot_telem = rx_pc_err + rx_ctrl_err + rx_reg_sbu + rx_imem_sbu + rx_dmem_sbu;
          tot_dbu   = rx_reg_dbu + rx_imem_dbu + rx_dmem_dbu;
          if (tot_dbu != 0 && expect_zero_sdc) begin
            $display("[FAIL] %0s run=%0d: DBU inesperado (%0d) en campaña SBE", label, r, tot_dbu);
            total_failures = total_failures + 1;
          end
          if (tot_telem > 0) corr_cnt = corr_cnt + 1;
          else latent_cnt = latent_cnt + 1;
        end
      end

      $display("[CAMPAIGN] %-22s | N=%0d | Inj=%0d (no-ack=%0d) | Match=%0d (Corr=%0d, Lat=%0d) | SDC=%0d | Hang=%0d",
               label, n_runs, inj_sum, zero_inj_cnt, match_cnt, corr_cnt, latent_cnt, sdc_cnt, hang_cnt);

      if (expect_zero_sdc && (sdc_cnt != 0 || hang_cnt != 0)) begin
        $display("[FAIL] %0s: Se esperaba SDC=0 y Hang=0 en configuracion protegida!", label);
        total_failures = total_failures + 1;
      end
      if (zero_inj_cnt > (n_runs / 20)) begin
        $display("[FAIL] %0s: Demasiadas corridas sin disparo ACK (%0d/%0d)", label, zero_inj_cnt, n_runs);
        total_failures = total_failures + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("build/dump.vcd");
    $dumpvars(0, tb_fault_campaign);

    if (!$value$plusargs("NUM_RUNS=%d", num_runs)) num_runs = DEFAULT_NUM_RUNS;
    if (!$value$plusargs("BASE_RUNS=%d", base_runs)) base_runs = num_runs;

    inj_resetn = 1'b0;
    dut_resetn = 1'b0;
    repeat (6) @(posedge clk);
    #1;
    inj_resetn = 1'b1;

    $display("====================================================================================");
    $display("  HPicoRV32 - Campana Estadistica de Inyeccion de Fallos (estilo HARV)");
    $display("  DUT: ENABLE_TMR=%0d ENABLE_REG_ECC=%0d | NUM_RUNS=%0d | BASE_RUNS=%0d",
             ENABLE_TMR, ENABLE_REG_ECC, num_runs, (RUN_BASELINE && ENABLE_TMR && ENABLE_REG_ECC) ? base_runs : 0);
    $display("====================================================================================");

    // -------------------------------------------------------------------------
    // Etapa 0: Golden Run sin fallos
    // -------------------------------------------------------------------------
    run_once(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 32'd0, 32'd100, 16'd0,
             4'd0, 3'd0, 39'd0, 15'h0001, 5000000);
    if (!run_done || run_trap || run_timeout) begin
      $display("[FAIL] Etapa 0 Golden Run no concluyo limpiamente (done=%b trap=%b to=%b)",
               run_done, run_trap, run_timeout);
      $fatal(1);
    end
    golden_result         = rx_result;
    golden_cycles         = run_cycles;
    golden_compute_cycles = run_comp_end - run_comp_start;

    $display("[GOLDEN] RESULT=0x%08x | total_cyc=%0d | compute_cyc=%0d (%0d..%0d) | UART_DIV+2=%0d",
             golden_result, golden_cycles, golden_compute_cycles, run_comp_start, run_comp_end, uart_bit_clks);
    if ((rx_pc_err | rx_ctrl_err | rx_reg_sbu | rx_reg_dbu |
         rx_imem_sbu | rx_imem_dbu | rx_dmem_sbu | rx_dmem_dbu) != 32'd0) begin
      $display("[FAIL] Etapa 0 reporto errores espureos de telemetria sin inyeccion!");
      $fatal(1);
    end

    // Evita VCDs multigigabyte en Icarus tras capturar Golden u_soc y antes de Etapa 2
    $dumpoff;

    if (RUN_BASELINE && ENABLE_TMR && ENABLE_REG_ECC && (base_runs > 0)) begin
      run_once(1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 32'd0, 32'd100, 16'd0,
               4'd0, 3'd0, 39'd0, 15'h0001, 5000000);
      if (!run_done || run_trap || run_timeout || (rx_result !== golden_result)) begin
        $display("[FAIL] Baseline Golden Run sin fallos fallo! (done=%b trap=%b to=%b res=0x%08x)",
                 run_done, run_trap, run_timeout, rx_result);
        $fatal(1);
      end
      $display("[GOLDEN-BASE] RESULT=0x%08x | total_cyc=%0d (baseline sin fallos OK)", rx_result, run_cycles);
    end

    // -------------------------------------------------------------------------
    // Etapa 1: Campanas estadisticas 1-SEU y 10-SEU (CPU-only y SoC)
    // -------------------------------------------------------------------------
    run_auto_campaign("SOC_PROT 1-SEU CPU",  1'b0, 1'b0, 1'b0, num_runs, 32'h1101_2026,
                      (ENABLE_TMR && ENABLE_REG_ECC));
    run_auto_campaign("SOC_PROT 1-SEU ALL",  1'b0, 1'b1, 1'b0, num_runs, 32'h2202_2026,
                      (ENABLE_TMR && ENABLE_REG_ECC));
    run_auto_campaign("SOC_PROT 10-SEU CPU", 1'b0, 1'b0, 1'b1, num_runs, 32'h3303_2026,
                      (ENABLE_TMR && ENABLE_REG_ECC));
    run_auto_campaign("SOC_PROT 10-SEU ALL", 1'b0, 1'b1, 1'b1, num_runs, 32'h4404_2026,
                      (ENABLE_TMR && ENABLE_REG_ECC));

    // Comparativa pareada A/B sin TMR ni Reg-ECC con las mismas semillas y perfiles CPU-only
    if (RUN_BASELINE && ENABLE_TMR && ENABLE_REG_ECC && (base_runs > 0)) begin
      run_auto_campaign("BASELINE 1-SEU CPU",  1'b1, 1'b0, 1'b0, base_runs, 32'h1101_2026, 1'b0);
      run_auto_campaign("BASELINE 10-SEU CPU", 1'b1, 1'b0, 1'b1, base_runs, 32'h3303_2026, 1'b0);
    end

    // -------------------------------------------------------------------------
    // Etapa 2: Verificacion dirigida de fallos fatales (DBE + Harvard W^X)
    // -------------------------------------------------------------------------
    $dumpon;
    if (ENABLE_REG_ECC) begin
      run_once(1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 32'd10, 32'd10, 16'd1,
               4'd5, 3'b001, 39'h00_0000_0003, 15'h0002, golden_cycles * 2);
      if (!run_trap || (run_inj_delta != 1) || !run_cpu_trap || (run_reg_dbu_hw < 1)) begin
        $display("[FAIL] Etapa 2.1 cpuregs DBE no disparo trap esperado (trap=%b inj=%0d dbu=%0d)",
                 run_trap, run_inj_delta, run_reg_dbu_hw);
        total_failures = total_failures + 1;
      end else begin
        $display("[TRAP PASS] Etapa 2.1: cpuregs DBE -> trap=%b cpu_trap=%b reg_dbu=%0d",
                 run_trap, run_cpu_trap, run_reg_dbu_hw);
      end
    end

    // Etapa 2.2: IMEM DBE -> ecc_fault_r & trap
    run_once(1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 32'd10, 32'd10, 16'd1,
             4'd6, 3'b001, 39'h00_0000_0003, 15'h0002, golden_cycles * 2);
    if (!run_trap || (run_inj_delta != 1) || !run_ecc_fault || (run_imem_dbu_hw < 1)) begin
      $display("[FAIL] Etapa 2.2 IMEM DBE no disparo trap esperado (trap=%b ecc_fault=%b dbu=%0d)",
               run_trap, run_ecc_fault, run_imem_dbu_hw);
      total_failures = total_failures + 1;
    end else begin
      $display("[TRAP PASS] Etapa 2.2: IMEM DBE -> trap=%b ecc_fault_r=%b imem_dbu=%0d",
               run_trap, run_ecc_fault, run_imem_dbu_hw);
    end

    // Etapa 2.3: DMEM DBE -> ecc_fault_r & trap
    run_once(1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 32'd10, 32'd10, 16'd1,
             4'd7, 3'b001, 39'h00_0000_0003, 15'h0002, golden_cycles * 2);
    if (!run_trap || (run_inj_delta != 1) || !run_ecc_fault || (run_dmem_dbu_hw < 1)) begin
      $display("[FAIL] Etapa 2.3 DMEM DBE no disparo trap esperado (trap=%b ecc_fault=%b dbu=%0d)",
               run_trap, run_ecc_fault, run_dmem_dbu_hw);
      total_failures = total_failures + 1;
    end else begin
      $display("[TRAP PASS] Etapa 2.3: DMEM DBE -> trap=%b ecc_fault_r=%b dmem_dbu=%0d",
               run_trap, run_ecc_fault, run_dmem_dbu_hw);
    end

    // Etapa 2.4: Salto Harvard W^X forzado en reg_next_pc (3 réplicas -> 0x0000_2000)
    run_once(1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 32'd10, 32'd10, 16'd1,
             4'd1, 3'b111, 39'h00_0000_2000, 15'h0002, golden_cycles * 2);
    if (!run_trap || (run_inj_delta != 1) || !run_harv_fault) begin
      $display("[FAIL] Etapa 2.4 Harvard W^X (reg_next_pc) no disparo harv_fault_r (trap=%b harv=%b)",
               run_trap, run_harv_fault);
      total_failures = total_failures + 1;
    end else begin
      $display("[TRAP PASS] Etapa 2.4: reg_next_pc W^X -> trap=%b harv_fault_r=%b",
               run_trap, run_harv_fault);
    end

    $display("====================================================================================");
    if (total_failures == 0) begin
      $display("[OK] Campana de inyeccion de fallos superada sin regresiones ni SDC.");
    end else begin
      $display("[FAIL] Se detectaron %0d fallos en la campana.", total_failures);
      $fatal(1);
    end
    $finish;
  end

endmodule
