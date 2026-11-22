// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       fault_injector.v
// Descripción:  Inyector de fallos hardware desacoplado (dirigido + LFSR)
// Reloj/Reset:  clk (flanco subida) | resetn (síncrono, activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module fault_injector #(
    parameter [31:0] DEFAULT_SEED = 32'hACE1_1357,
    parameter [31:0] ACK_TIMEOUT  = 32'd10000
) (
    input clk,    // Reloj del sistema (100 MHz)
    input resetn, // Reset síncrono activo bajo

    // Control de modo y perfil
    input        enable_i,       // 1 = habilita campañas autónomas por LFSR
    input        auto_mode_i,    // 0 = disparo dirigido (trig_i); 1 = autónomo LFSR
    input        soc_profile_i,  // 0 = CPU-only (0..5, estilo HARV); 1 = SoC (0..7)
    input        reg_ecc_en_i,   // 1 = cpuregs de 39b; 0 = 32b (ENABLE_REG_ECC=0)
    input        dbe_mode_i,     // 0 = SEU/SBE (1 bit/1 réplica); 1 = DBE/MBU (2 bits/réplicas)
    input        trig_i,         // Pulso de disparo en modo dirigido
    input        seed_load_i,    // Carga síncrona de semilla para reproducibilidad
    input [31:0] seed_i,         // Semilla externa (si vale 0, se sustituye por DEFAULT_SEED)

    // Configuración para modo dirigido (auto_mode_i == 0)
    input [ 3:0] cfg_target_i,    // Objetivo 0..7
    input [ 2:0] cfg_rep_mask_i,  // Réplicas TMR a atacar (bits [2:0])
    input [38:0] cfg_bit_mask_i,  // Máscara XOR de hasta 39 bits

    // Parámetros para modo autónomo (auto_mode_i == 1)
    input [31:0] interval_i,   // Ciclos de espera entre inyecciones (mín. 1)
    input [15:0] max_faults_i, // Presupuesto (1 = 1-SEU, 10 = 10-SEU, 0 = infinito)

    // Bus de inyección desacoplado hacia soc_core (salidas registradas)
    output reg        fi_valid_o,     // Solicitud armada hacia el SoC
    output reg [ 3:0] fi_target_o,    // Objetivo seleccionado
    output reg [ 2:0] fi_rep_mask_o,  // Máscara de réplicas TMR
    output reg [38:0] fi_bit_mask_o,  // Máscara XOR de inversión de bits
    input             fi_ack_i,       // Pulso combinacional de consumo desde el SoC

    // Telemetría propia del inyector
    output reg [31:0] inj_count_o,  // Fallos realmente consumidos (fi_valid_o && fi_ack_i)
    output reg        fi_timeout_o  // Pulso de 1 ciclo si expira ACK_TIMEOUT
);

  // ---------------------------------------------------------------------------
  // Bloque 1: PRNG LFSR de 32 bits (periodo máximo 2^32 - 1)
  // Realimentación taps [31, 21, 1, 0] -> polinomio primitivo en 1 sola LUT4
  // ---------------------------------------------------------------------------
  reg  [31:0] lfsr_q;
  wire        lfsr_fb = lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0];
  wire [31:0] seed_safe = (|seed_i) ? seed_i : DEFAULT_SEED;

  always @(posedge clk) begin
    if (!resetn) begin
      lfsr_q <= DEFAULT_SEED;
    end else if (seed_load_i) begin
      lfsr_q <= seed_safe;
    end else begin
      lfsr_q <= {lfsr_q[30:0], lfsr_fb};
    end
  end

  // ---------------------------------------------------------------------------
  // Bloque 2: Muestreo uniforme (sin sesgo cruzado) y generador de máscaras
  // ---------------------------------------------------------------------------
  // Rebanadas separadas y mezcladas por XOR para evitar correlación al desplazar
  wire [2:0] cand_tgt = {lfsr_q[25], lfsr_q[14], lfsr_q[3]};
  wire tgt_ok = soc_profile_i ? 1'b1 : (cand_tgt <= 3'd5);

  wire [1:0] cand_rep = {lfsr_q[27] ^ lfsr_q[11], lfsr_q[17] ^ lfsr_q[2]};
  wire [5:0] cand_b0  = {lfsr_q[30], lfsr_q[24], lfsr_q[19], lfsr_q[13], lfsr_q[7], lfsr_q[1]} ^
                        {lfsr_q[15], lfsr_q[10], lfsr_q[5],  lfsr_q[29], lfsr_q[20], lfsr_q[17]};
  wire [5:0] cand_b1  = {lfsr_q[31], lfsr_q[26], lfsr_q[21], lfsr_q[16], lfsr_q[8], lfsr_q[4]} ^
                        {lfsr_q[18], lfsr_q[12], lfsr_q[9],  lfsr_q[0],  lfsr_q[28], lfsr_q[22]};

  wire is_tmr_tgt = (fi_target_o <= 4'd4);
  wire rep_ok = is_tmr_tgt ? (cand_rep != 2'd3) : 1'b1;
  wire need_second_bit = dbe_mode_i && !is_tmr_tgt;

  reg [5:0] bit_idx0;
  reg [5:0] bit_idx1;
  reg bit0_ok;
  reg bit1_ok;

  // Acota y valida el rango de bit según el ancho real de fi_target_o
  always @* begin
    bit_idx0 = 6'd0;
    bit_idx1 = 6'd0;
    bit0_ok  = 1'b0;
    bit1_ok  = 1'b0;

    case (fi_target_o[2:0])
      3'd0, 3'd1: begin  // reg_pc / reg_next_pc (32 bits)
        bit_idx0 = {1'b0, cand_b0[4:0]};
        bit_idx1 = {1'b0, cand_b1[4:0]};
        bit0_ok  = 1'b1;
        bit1_ok  = 1'b1;
      end
      3'd2: begin  // cpu_state (8 bits)
        bit_idx0 = {3'b000, cand_b0[2:0]};
        bit_idx1 = {3'b000, cand_b1[2:0]};
        bit0_ok  = 1'b1;
        bit1_ok  = 1'b1;
      end
      3'd3: begin  // mem_state (2 bits)
        bit_idx0 = {5'b00000, cand_b0[0]};
        bit_idx1 = {5'b00000, cand_b1[0]};
        bit0_ok  = 1'b1;
        bit1_ok  = 1'b1;
      end
      3'd4: begin  // latched_rd (5 bits)
        bit_idx0 = {3'b000, cand_b0[2:0]};
        bit_idx1 = {3'b000, cand_b1[2:0]};
        bit0_ok  = (cand_b0[2:0] < 3'd5);
        bit1_ok  = (cand_b1[2:0] < 3'd5);
      end
      3'd5: begin  // cpuregs (39 bits con ECC, 32 bits sin ECC)
        if (reg_ecc_en_i) begin
          bit_idx0 = cand_b0;
          bit_idx1 = cand_b1;
          bit0_ok  = (cand_b0 < 6'd39);
          bit1_ok  = (cand_b1 < 6'd39);
        end else begin
          bit_idx0 = {1'b0, cand_b0[4:0]};
          bit_idx1 = {1'b0, cand_b1[4:0]};
          bit0_ok  = 1'b1;
          bit1_ok  = 1'b1;
        end
      end
      3'd6, 3'd7: begin  // imem / dmem (39 bits)
        bit_idx0 = cand_b0;
        bit_idx1 = cand_b1;
        bit0_ok  = (cand_b0 < 6'd39);
        bit1_ok  = (cand_b1 < 6'd39);
      end
    endcase
  end

  wire pick_ok = rep_ok && bit0_ok && (!need_second_bit || (bit1_ok && (bit_idx1 != bit_idx0)));

  // Decodificador one-hot (1 bit/réplica) y two-hot (DBE: 2 bits; MBU TMR: 2 réplicas)
  wire [2:0] rep_one_hot = (3'b001 << cand_rep);
  wire [2:0] rand_rep_mask = !is_tmr_tgt ? 3'b001 : (dbe_mode_i ? ~rep_one_hot : rep_one_hot);
  wire [38:0] mask_bit0 = (39'd1 << bit_idx0);
  wire [38:0] mask_bit1 = need_second_bit ? (39'd1 << bit_idx1) : 39'd0;
  wire [38:0] rand_bit_mask = mask_bit0 | mask_bit1;

  // ---------------------------------------------------------------------------
  // Bloque 3: FSM de control (ST_IDLE -> ST_PICK -> ST_ARMED) y temporizador
  // ---------------------------------------------------------------------------
  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_PICK = 2'd1;
  localparam [1:0] ST_ARMED = 2'd2;

  localparam [31:0] TIMEOUT_LIM = (ACK_TIMEOUT > 32'd0) ? (ACK_TIMEOUT - 32'd1) : 32'd0;

  reg  [ 1:0] state_q;
  reg  [31:0] timer_q;
  reg  [15:0] auto_sent_q;
  reg         trig_q;

  wire        auto_active = enable_i && auto_mode_i;
  wire        trig_pulse = trig_i && !trig_q && !auto_mode_i;
  wire        budget_ok = (max_faults_i == 16'd0) || (auto_sent_q < max_faults_i);
  wire [31:0] interval_eff = (|interval_i) ? interval_i : 32'd1;
  wire [31:0] interval_lim = interval_eff - 32'd1;

  always @(posedge clk) begin
    fi_timeout_o <= 1'b0;

    if (!resetn) begin
      state_q       <= ST_IDLE;
      timer_q       <= 32'd0;
      auto_sent_q   <= 16'd0;
      trig_q        <= 1'b0;
      fi_valid_o    <= 1'b0;
      fi_target_o   <= 4'd0;
      fi_rep_mask_o <= 3'd0;
      fi_bit_mask_o <= 39'd0;
      inj_count_o   <= 32'd0;
      fi_timeout_o  <= 1'b0;
    end else begin
      trig_q <= trig_i;

      case (state_q)
        ST_IDLE: begin
          fi_valid_o <= 1'b0;
          if (!auto_active) auto_sent_q <= 16'd0;

          if (trig_pulse) begin
            // Disparo dirigido: carga directa sin pasar por el LFSR
            fi_target_o   <= cfg_target_i;
            fi_rep_mask_o <= cfg_rep_mask_i;
            fi_bit_mask_o <= cfg_bit_mask_i;
            fi_valid_o    <= 1'b1;
            timer_q       <= 32'd0;
            state_q       <= ST_ARMED;
          end else if (auto_active && budget_ok) begin
            if (timer_q < interval_lim) begin
              timer_q <= timer_q + 32'd1;
            end else if (tgt_ok) begin
              // Fija el objetivo primero (paso 1 del muestreo sin sesgo)
              fi_target_o <= {1'b0, cand_tgt};
              timer_q     <= 32'd0;
              state_q     <= ST_PICK;
            end
          end else begin
            timer_q <= 32'd0;
          end
        end

        ST_PICK: begin
          if (!auto_active) begin
            state_q <= ST_IDLE;
          end else if (pick_ok) begin
            // Fija réplica y máscara válidas para fi_target_o y arma el bus FI
            fi_rep_mask_o <= rand_rep_mask;
            fi_bit_mask_o <= rand_bit_mask;
            fi_valid_o    <= 1'b1;
            auto_sent_q   <= auto_sent_q + 16'd1;
            timer_q       <= 32'd0;
            state_q       <= ST_ARMED;
          end
        end

        ST_ARMED: begin
          if (fi_valid_o && fi_ack_i) begin
            fi_valid_o  <= 1'b0;
            inj_count_o <= inj_count_o + 32'd1;
            timer_q     <= 32'd0;
            state_q     <= ST_IDLE;
          end else if ((ACK_TIMEOUT != 32'd0) && (timer_q >= TIMEOUT_LIM)) begin
            fi_valid_o   <= 1'b0;
            fi_timeout_o <= 1'b1;
            timer_q      <= 32'd0;
            state_q      <= ST_IDLE;
          end else begin
            timer_q <= timer_q + 32'd1;
          end
        end

        default: begin
          fi_valid_o <= 1'b0;
          timer_q    <= 32'd0;
          state_q    <= ST_IDLE;
        end
      endcase
    end
  end
endmodule
