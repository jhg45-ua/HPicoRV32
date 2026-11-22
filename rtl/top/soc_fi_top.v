// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       soc_fi_top.v
// Descripción:  Top de laboratorio Nexys A7-100T con inyector FI por SW[4:0]/BTNC
// Reloj/Reset:  clk (flanco subida, 100 MHz) | resetn (activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module soc_fi_top #(
    parameter integer IMEM_WORDS      = 2048,
    parameter integer DMEM_WORDS      = 2048,
    parameter [0:0]   ENABLE_TMR      = 1'b1,
    parameter [0:0]   ENABLE_REG_ECC  = 1'b1,
    parameter         FIRMWARE_FILE   = "build/firmware.hex",
    parameter integer DEBOUNCE_CYCLES = 1000000,               // 10 ms @ 100 MHz
    parameter [31:0]  AUTO_INTERVAL   = 32'd10000000           // 10 fallos/s @ 100 MHz
) (
    input         clk,     // Reloj principal 100 MHz (E3)
    input         resetn,  // Botón CPU_RESETN activo bajo (C12)
    output        trap,    // LED15: CPU trap, Harvard W^X o DBE ECC
    output [14:0] leds,    // LEDs 0..14 de usuario
    output        ser_tx,  // UART TX hacia PC
    input         ser_rx,  // UART RX desde PC
    // Controles físicos del inyector en placa:
    // - sw[2:0]: objetivo (0=PC, 1=next_PC, 2=cpu_st, 3=mem_st, 4=rd, 5=regs, 6=IMEM, 7=DMEM)
    // - sw[3]  : 0 = SBE / 1 réplica TMR | 1 = DBE / MBU fatal (W^X en target=1)
    // - sw[4]  : 0 = disparo manual por BTNC | 1 = campaña autónoma continua LFSR
    input  [ 4:0] sw,
    input         btnc
);

  // ---------------------------------------------------------------------------
  // 1. Power-On Reset (POR) local: mantiene sys_resetn a 0 los primeros 63 ciclos
  //    para arrancar sincronizadores, debouncer e inyector en estado limpio.
  // ---------------------------------------------------------------------------
  reg [5:0] reset_cnt = 6'd0;
  wire sys_resetn = &reset_cnt;

  always @(posedge clk) begin
    if (!resetn) reset_cnt <= 6'd0;
    else if (!sys_resetn) reset_cnt <= reset_cnt + 6'd1;
  end

  // ---------------------------------------------------------------------------
  // 2. Sincronizadores de 2 flip-flops (anti-metaestabilidad)
  //    Los switches y botones de la Nexys A7 cambian sin relación con clk (100 MHz).
  //    Si un cambio cae justo en la ventana de setup/hold del FF, su salida puede
  //    quedar indecisa (metaestable). Dos FFs en serie dan 1 ciclo para estabilizarla.
  // ---------------------------------------------------------------------------
  reg [4:0] sw_sync0_q;
  reg [4:0] sw_sync1_q;
  reg       btnc_sync0_q;
  reg       btnc_sync1_q;

  always @(posedge clk) begin
    if (!sys_resetn) begin
      sw_sync0_q   <= 5'd0;
      sw_sync1_q   <= 5'd0;
      btnc_sync0_q <= 1'b0;
      btnc_sync1_q <= 1'b0;
    end else begin
      sw_sync0_q   <= sw;
      sw_sync1_q   <= sw_sync0_q;
      btnc_sync0_q <= btnc;
      btnc_sync1_q <= btnc_sync0_q;
    end
  end

  // ---------------------------------------------------------------------------
  // 3. Filtro antirrebote (debouncer) de 10 ms + detector de flanco para BTNC
  //    Al pulsar un botón mecánico, los contactos rebotan varios milisegundos.
  //    Solo aceptamos el nuevo estado cuando permanece igual 1,000,000 ciclos (10 ms).
  //    btn_trig genera un pulso de exactamente 1 ciclo al pulsar el botón.
  // ---------------------------------------------------------------------------
  localparam [31:0] DEB_LIM = (DEBOUNCE_CYCLES > 1) ? (DEBOUNCE_CYCLES - 1) : 32'd0;
  reg [31:0] deb_cnt_q;
  reg        btnc_state_q;
  reg        btnc_prev_q;

  always @(posedge clk) begin
    if (!sys_resetn) begin
      deb_cnt_q    <= 32'd0;
      btnc_state_q <= 1'b0;
      btnc_prev_q  <= 1'b0;
    end else begin
      btnc_prev_q <= btnc_state_q;

      if (btnc_sync1_q == btnc_state_q) begin
        deb_cnt_q <= 32'd0;
      end else if (deb_cnt_q >= DEB_LIM) begin
        btnc_state_q <= btnc_sync1_q;
        deb_cnt_q    <= 32'd0;
      end else begin
        deb_cnt_q <= deb_cnt_q + 32'd1;
      end
    end
  end

  wire        btn_trig = btnc_state_q && !btnc_prev_q;
  wire [ 2:0] sw_target = sw_sync1_q[2:0];  // Objetivo FI (0..7)
  wire        sw_dbe = sw_sync1_q[3];       // 0 = corregible (SBE/1 rep); 1 = fatal (DBE/MBU/W^X)
  wire        sw_auto = sw_sync1_q[4];      // 0 = manual por BTNC; 1 = autónomo continuo LFSR

  // ---------------------------------------------------------------------------
  // 4. Traductor de switches a máscara dirigida (para modo manual sw[4]=0)
  //    - En targets TMR (0..4): sw_dbe=0 -> 1 réplica (3'b001); sw_dbe=1 -> 2 réplicas (3'b011)
  //    - Caso especial W^X (sw_target=1 reg_next_pc + sw_dbe=1): ataca las 3 réplicas (3'b111)
  //      con máscara 0x2000 para saltar a la zona DMEM y probar el trap Harvard W^X (LED15).
  //    - En cpuregs/IMEM/DMEM (5..7): sw_dbe=0 -> 1 bit (39'h1); sw_dbe=1 -> 2 bits (39'h3).
  // ---------------------------------------------------------------------------
  wire        is_tmr_sel = (sw_target <= 3'd4);
  wire [ 2:0] cfg_rep_mask = !sw_dbe ? 3'b001 :
                             (!is_tmr_sel ? 3'b001 : ((sw_target == 3'd1) ? 3'b111 : 3'b011));
  wire [38:0] cfg_bit_mask = !sw_dbe ? 39'h00_0000_0001 :
                             (is_tmr_sel ? ((sw_target == 3'd1) ? 39'h00_0000_2000 : 39'h00_0000_0001) :
                                           39'h00_0000_0003);

  wire        fi_valid;
  wire [ 3:0] fi_target;
  wire [ 2:0] fi_rep_mask;
  wire [38:0] fi_bit_mask;
  wire        fi_ack;

  // ---------------------------------------------------------------------------
  // 5. Inyector de fallos físico
  //    ACK_TIMEOUT = 2,000,000 ciclos (20 ms @ 100 MHz): margen suficiente para que
  //    un disparo manual sobre DMEM espere sin caducar mientras counter imprime por UART (~11 ms).
  // ---------------------------------------------------------------------------
  fault_injector #(
      .ACK_TIMEOUT(32'd2000000)
  ) u_injector (
      .clk           (clk),
      .resetn        (sys_resetn),
      .enable_i      (sw_auto),
      .auto_mode_i   (sw_auto),
      .soc_profile_i (1'b1),
      .reg_ecc_en_i  (ENABLE_REG_ECC),
      .dbe_mode_i    (sw_dbe),
      .trig_i        (btn_trig),
      .seed_load_i   (1'b0),
      .seed_i        (32'h0),
      .cfg_target_i  ({1'b0, sw_target}),
      .cfg_rep_mask_i(cfg_rep_mask),
      .cfg_bit_mask_i(cfg_bit_mask),
      .interval_i    (AUTO_INTERVAL),
      .max_faults_i  (16'd0),
      .fi_valid_o    (fi_valid),
      .fi_target_o   (fi_target),
      .fi_rep_mask_o (fi_rep_mask),
      .fi_bit_mask_o (fi_bit_mask),
      .fi_ack_i      (fi_ack),
      .inj_count_o   (),
      .fi_timeout_o  ()
  );

  soc_core #(
      .IMEM_WORDS    (IMEM_WORDS),
      .DMEM_WORDS    (DMEM_WORDS),
      .ENABLE_TMR    (ENABLE_TMR),
      .ENABLE_REG_ECC(ENABLE_REG_ECC),
      .FIRMWARE_FILE (FIRMWARE_FILE),
      .ENABLE_FI     (1'b1)
  ) u_core (
      .clk          (clk),
      .resetn       (resetn),
      .trap         (trap),
      .leds         (leds),
      .ser_tx       (ser_tx),
      .ser_rx       (ser_rx),
      .fi_valid_i   (fi_valid),
      .fi_target_i  (fi_target),
      .fi_rep_mask_i(fi_rep_mask),
      .fi_bit_mask_i(fi_bit_mask),
      .fi_ack_o     (fi_ack)
  );

endmodule
