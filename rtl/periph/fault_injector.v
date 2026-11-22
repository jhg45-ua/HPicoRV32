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
  // Bloque 1: PRNG LFSR de 32 bits (generador pseudoaleatorio hardware)
  // Un LFSR desplaza los bits a la izquierda y mete por bit 0 el XOR de 4 bits
  // ("taps" [31, 21, 1, 0]). Con estos taps recorre los 2^32 - 1 estados sin repetir.
  // ---------------------------------------------------------------------------
  reg  [31:0] lfsr_q;
  wire        lfsr_fb = lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0];
  // Protección contra bloqueo: un LFSR lleno de ceros siempre genera ceros (XOR(0)=0),
  // así que si seed_i vale 0 cargamos DEFAULT_SEED.
  wire [31:0] seed_safe = (|seed_i) ? seed_i : DEFAULT_SEED;

  always @(posedge clk) begin
    if (!resetn) begin
      lfsr_q <= DEFAULT_SEED;
    end else if (seed_load_i) begin
      lfsr_q <= seed_safe;
    end else begin
      lfsr_q <= {lfsr_q[30:0], lfsr_fb};  // Desplaza 1 bit cada ciclo continuamente
    end
  end

  // ---------------------------------------------------------------------------
  // Bloque 2: Selección sin sesgo (rejection sampling) y generador de máscaras
  // ---------------------------------------------------------------------------
  // En vez de usar '%' (que gasta divisores enormes en FPGA y sesga hacia números bajos),
  // cogemos bits separados del LFSR (mezclados con XOR para evitar correlaciones al
  // desplazar) y descartamos los que se pasen del rango válido (1 ciclo más si falla).
  wire [2:0] cand_tgt = {lfsr_q[25], lfsr_q[14], lfsr_q[3]};
  wire tgt_ok = soc_profile_i ? 1'b1 : (cand_tgt <= 3'd5);  // CPU-only = 0..5, SoC = 0..7

  wire [1:0] cand_rep = {lfsr_q[27] ^ lfsr_q[11], lfsr_q[17] ^ lfsr_q[2]};
  // Dos candidatos independientes de 6 bits (0..63): b0 para SBE y b1 para el segundo bit si hay DBE
  wire [5:0] cand_b0  = {lfsr_q[30], lfsr_q[24], lfsr_q[19], lfsr_q[13], lfsr_q[7], lfsr_q[1]} ^
                        {lfsr_q[15], lfsr_q[10], lfsr_q[5],  lfsr_q[29], lfsr_q[20], lfsr_q[17]};
  wire [5:0] cand_b1  = {lfsr_q[31], lfsr_q[26], lfsr_q[21], lfsr_q[16], lfsr_q[8], lfsr_q[4]} ^
                        {lfsr_q[18], lfsr_q[12], lfsr_q[9],  lfsr_q[0],  lfsr_q[28], lfsr_q[22]};

  // Targets 0..4 son registros TMR (3 réplicas); 5..7 son memorias/cpuregs protegidas por ECC
  wire is_tmr_tgt = (fi_target_o <= 4'd4);
  // Solo existen 3 réplicas (0, 1, 2): rechazamos cand_rep == 3 para repartir al 33.3% exacto
  wire rep_ok = is_tmr_tgt ? (cand_rep != 2'd3) : 1'b1;
  // En DBE sobre memorias/cpuregs necesitamos 2 bits distintos en la misma palabra; en TMR atacamos 2 réplicas
  wire need_second_bit = dbe_mode_i && !is_tmr_tgt;

  reg [5:0] bit_idx0;
  reg [5:0] bit_idx1;
  reg bit0_ok;
  reg bit1_ok;

  // Paso 2 (combinacional tras fijar fi_target_o): ajusta cand_b0/b1 al ancho real del objetivo
  always @* begin
    bit_idx0 = 6'd0;
    bit_idx1 = 6'd0;
    bit0_ok  = 1'b0;
    bit1_ok  = 1'b0;

    case (fi_target_o[2:0])
      3'd0, 3'd1: begin  // reg_pc / reg_next_pc (32 bits exactos -> potencia de 2, siempre válido)
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
      3'd4: begin  // latched_rd (5 bits: solo índices 0..4 son válidos)
        bit_idx0 = {3'b000, cand_b0[2:0]};
        bit_idx1 = {3'b000, cand_b1[2:0]};
        bit0_ok  = (cand_b0[2:0] < 3'd5);
        bit1_ok  = (cand_b1[2:0] < 3'd5);
      end
      3'd5: begin  // cpuregs (39 bits si tiene ECC Hsiao, 32 bits si ENABLE_REG_ECC=0)
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
      3'd6, 3'd7: begin  // imem / dmem (39 bits = 32 datos + 7 paridad)
        bit_idx0 = cand_b0;
        bit_idx1 = cand_b1;
        bit0_ok  = (cand_b0 < 6'd39);
        bit1_ok  = (cand_b1 < 6'd39);
      end
    endcase
  end

  // Para DBE exigimos además que ambos bits elegidos sean distintos (si coincidieran se cancelarían)
  wire pick_ok = rep_ok && bit0_ok && (!need_second_bit || (bit1_ok && (bit_idx1 != bit_idx0)));

  // Convierte el índice binario a máscara de bits:
  // - En TMR: ~rep_one_hot deja a 1 las otras 2 réplicas para provocar MBU fatal (vota mal)
  // - En datos: desplaza un '1' a bit_idx0 (y a bit_idx1 en DBE)
  wire [2:0] rep_one_hot = (3'b001 << cand_rep);
  wire [2:0] rand_rep_mask = !is_tmr_tgt ? 3'b001 : (dbe_mode_i ? ~rep_one_hot : rep_one_hot);
  wire [38:0] mask_bit0 = (39'd1 << bit_idx0);
  wire [38:0] mask_bit1 = need_second_bit ? (39'd1 << bit_idx1) : 39'd0;
  wire [38:0] rand_bit_mask = mask_bit0 | mask_bit1;

  // ---------------------------------------------------------------------------
  // Bloque 3: FSM de control (ST_IDLE -> ST_PICK -> ST_ARMED) y temporizador
  // ---------------------------------------------------------------------------
  // Separamos ST_IDLE (elige objetivo o espera intervalo) de ST_PICK (elige bit en el
  // ciclo siguiente con el LFSR ya avanzado) para eliminar sesgo y acortar caminos críticos.
  localparam [1:0] ST_IDLE = 2'd0;
  localparam [1:0] ST_PICK = 2'd1;
  localparam [1:0] ST_ARMED = 2'd2;

  localparam [31:0] TIMEOUT_LIM = (ACK_TIMEOUT > 32'd0) ? (ACK_TIMEOUT - 32'd1) : 32'd0;

  reg  [ 1:0] state_q;
  reg  [31:0] timer_q;      // Contador compartido: espera entre fallos en ST_IDLE / watchdog en ST_ARMED
  reg  [15:0] auto_sent_q;  // Fallos armados en la campaña autónoma actual
  reg         trig_q;       // Copia retrasada 1 ciclo de trig_i para detectar flanco de subida
  reg         armed_auto_q; // 1 = el fallo armado nació en modo autónomo; 0 = nació por botón/trig dirigido

  wire        auto_active = enable_i && auto_mode_i;
  // Detector de flanco de subida: aunque trig_i siga alto varios ciclos, trig_pulse dura solo 1
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
      armed_auto_q  <= 1'b0;
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
            // Disparo dirigido: carga directa sin pasar por el LFSR (salta ST_PICK)
            fi_target_o   <= cfg_target_i;
            fi_rep_mask_o <= cfg_rep_mask_i;
            fi_bit_mask_o <= cfg_bit_mask_i;
            fi_valid_o    <= 1'b1;
            armed_auto_q  <= 1'b0;
            timer_q       <= 32'd0;
            state_q       <= ST_ARMED;
          end else if (auto_active && budget_ok) begin
            // Espera interval_i ciclos antes de preparar el siguiente fallo autónomo
            if (timer_q < interval_lim) begin
              timer_q <= timer_q + 32'd1;
            end else if (tgt_ok) begin
              // Paso 1: fija objetivo válido y salta a ST_PICK para elegir bit al ciclo siguiente
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
            // Paso 2: ya con fi_target_o estable y LFSR avanzado, fija réplica/máscara y arma fi_valid_o
            fi_rep_mask_o <= rand_rep_mask;
            fi_bit_mask_o <= rand_bit_mask;
            fi_valid_o    <= 1'b1;
            armed_auto_q  <= 1'b1;
            auto_sent_q   <= auto_sent_q + 16'd1;
            timer_q       <= 32'd0;
            state_q       <= ST_ARMED;
          end
        end

        ST_ARMED: begin
          if (fi_valid_o && fi_ack_i) begin
            // El módulo destino aceptó el fallo en este flanco: desarma y cuenta la inyección
            fi_valid_o  <= 1'b0;
            inj_count_o <= inj_count_o + 32'd1;
            timer_q     <= 32'd0;
            state_q     <= ST_IDLE;
          end else if (armed_auto_q && !auto_active) begin
            // Si el usuario apaga el modo autónomo mientras esperaba ACK (p. ej. DMEM), aborta limpio
            fi_valid_o  <= 1'b0;
            timer_q     <= 32'd0;
            state_q     <= ST_IDLE;
          end else if ((ACK_TIMEOUT != 32'd0) && (timer_q >= TIMEOUT_LIM)) begin
            // Watchdog de seguridad: evita quedar colgado para siempre si nadie lee el destino
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
