// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       bram_ecc.v
// Descripción:  Controlador ECC Hsiao (39,32) sobre BRAM con scrubbing y RMW
// Reloj/Reset:  clk (flanco subida) | resetn (activo bajo)
// =============================================================================

module bram_ecc #(
    parameter integer       WORDS     = 2048,
    parameter integer       ADDR_BITS = 11,
    parameter         [0:0] READ_ONLY = 1'b0,
    parameter         [0:0] USE_INIT  = 1'b0,
    parameter               INIT_FILE = "build/firmware.hex"
) (
    input                      clk,      // Reloj del sistema (flanco de subida)
    input                      resetn,   // Reset síncrono activo bajo (solo FSM y salidas)
    input                      valid_i,  // Solicitud activa desde el bus del SoC
    input      [          3:0] wstrb_i,  // 4'b0000 = lectura; 4'b1111 = sw; otro = RMW sb/sh
    input      [ADDR_BITS-1:0] addr_i,   // Dirección de palabra
    input      [         31:0] wdata_i,  // Dato de escritura (32 bits)
    output reg [         31:0] rdata_o,  // Dato decodificado y registrado (válido con ready_o)
    output reg                 ready_o,  // Pulso síncrono de 1 ciclo al completar transacción
    output reg                 sbe_o,    // Pulso de 1 ciclo: error simple corregido (+ scrub)
    output reg                 dbe_o     // Pulso de 1 ciclo: error doble incorregible (fatal)
);

  localparam [2:0] ST_IDLE = 3'd0;
  localparam [2:0] ST_READ = 3'd1;
  localparam [2:0] ST_SCRUB = 3'd2;
  localparam [2:0] ST_RMW_READ = 3'd3;
  localparam [2:0] ST_RMW_WRITE = 3'd4;

  reg  [          2:0] state;
  reg  [ADDR_BITS-1:0] addr_q;
  reg  [          3:0] wstrb_q;
  reg  [         31:0] wdata_q;
  reg  [         31:0] rmw_base_q;  // Palabra previa ya decodificada para mezcla RMW
  reg  [         38:0] scrub_word_q;  // Palabra de 39b reparada para reescribir en ST_SCRUB

  // Señales combinacionales hacia la BRAM física single-port de 39 bits
  reg                  bram_en;
  reg                  bram_we;
  reg  [ADDR_BITS-1:0] bram_addr;
  reg  [         38:0] bram_wdata;
  wire [         38:0] bram_rdata;

  // Decodificador combinacional permanente sobre la salida registrada de la BRAM
  wire [         31:0] dec_data;
  wire [          6:0] dec_ecc;
  wire                 dec_sbiterr;
  wire                 dec_dbiterr;

  ecc_secded_dec u_dec (
      .encoded_i(bram_rdata),
      .data_o   (dec_data),
      .ecc_o    (dec_ecc),
      .sbiterr_o(dec_sbiterr),
      .dbiterr_o(dec_dbiterr)
  );

  // Mezcla combinacional por bytes para sb/sh y codificador Hsiao único compartido (sw / RMW)
  wire [31:0] rmw_merged_data = {
    wstrb_q[3] ? wdata_q[31:24] : rmw_base_q[31:24],
    wstrb_q[2] ? wdata_q[23:16] : rmw_base_q[23:16],
    wstrb_q[1] ? wdata_q[15:8] : rmw_base_q[15:8],
    wstrb_q[0] ? wdata_q[7:0] : rmw_base_q[7:0]
  };
  wire [31:0] enc_data_in = (state == ST_RMW_WRITE) ? rmw_merged_data : wdata_i;
  wire [38:0] enc_word;

  ecc_secded_enc u_enc (
      .data_i   (enc_data_in),
      .encoded_o(enc_word)
  );

  // Matriz física de 39 bits con escritura atómica (BYTE_WRITE=0)
  bram_sp #(
      .WORDS     (WORDS),
      .ADDR_BITS (ADDR_BITS),
      .DATA_WIDTH(39),
      .BYTE_WRITE(1'b0),
      .USE_INIT  (USE_INIT),
      .INIT_FILE (INIT_FILE)
  ) u_bram (
      .clk  (clk),
      .en   (bram_en),
      .wstrb({4{bram_we}}),
      .addr (bram_addr),
      .wdata(bram_wdata),
      .rdata(bram_rdata)
  );

  // Arranque válido en reposo (ignora valid_i mientras el pulso ready_o sigue alto 1 ciclo)
  wire start_access = resetn && valid_i && !ready_o;
  wire is_write_full = !READ_ONLY && (wstrb_i == 4'b1111);

  // Multiplexor combinacional de control hacia u_bram (valores por defecto evitan latches)
  always @* begin
    bram_en    = 1'b0;
    bram_we    = 1'b0;
    bram_addr  = addr_q;
    bram_wdata = enc_word;

    case (state)
      ST_IDLE: begin
        if (start_access) begin
          bram_en   = 1'b1;
          bram_we   = is_write_full;
          bram_addr = addr_i;
        end
      end
      ST_SCRUB: begin
        bram_en    = 1'b1;
        bram_we    = 1'b1;
        bram_wdata = scrub_word_q;
      end
      ST_RMW_WRITE: begin
        bram_en = 1'b1;
        bram_we = 1'b1;
      end
      default: begin
        bram_en = 1'b0;
        bram_we = 1'b0;
      end
    endcase
  end

  // FSM secuencial: registra lectura decodificada, dispara scrubbing/RMW y pulsos de 1 ciclo
  always @(posedge clk) begin
    ready_o <= 1'b0;
    sbe_o   <= 1'b0;
    dbe_o   <= 1'b0;

    if (!resetn) begin
      state        <= ST_IDLE;
      addr_q       <= {ADDR_BITS{1'b0}};
      wstrb_q      <= 4'b0000;
      wdata_q      <= 32'h0;
      rmw_base_q   <= 32'h0;
      scrub_word_q <= 39'h0;
      rdata_o      <= 32'h0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (start_access) begin
            addr_q  <= addr_i;
            wstrb_q <= wstrb_i;
            wdata_q <= wdata_i;

            if (is_write_full) begin
              // Escritura sw completa: u_bram ya capturó enc_word en este flanco
              ready_o <= 1'b1;
            end else if (!READ_ONLY && (|wstrb_i)) begin
              // Escritura parcial sb/sh: lee primero la palabra de 39b para RMW
              state <= ST_RMW_READ;
            end else begin
              // Lectura (o intento de escritura bloqueado por READ_ONLY)
              state <= ST_READ;
            end
          end
        end

        ST_READ: begin
          // Aísla BRAM + ecc_secded_dec de la CPU registrando el dato limpio
          rdata_o <= dec_data;

          if (dec_dbiterr) begin
            // Error doble: señala fallo fatal sin sobrescribir ni colgar el bus
            dbe_o   <= 1'b1;
            ready_o <= 1'b1;
            state   <= ST_IDLE;
          end else if (dec_sbiterr) begin
            // Error simple: guarda palabra reparada y reescribe en ST_SCRUB
            scrub_word_q <= {dec_ecc, dec_data};
            sbe_o        <= 1'b1;
            state        <= ST_SCRUB;
          end else begin
            ready_o <= 1'b1;
            state   <= ST_IDLE;
          end
        end

        ST_SCRUB: begin
          // u_bram ya reescribió scrub_word_q en este flanco; libera transacción
          ready_o <= 1'b1;
          state   <= ST_IDLE;
        end

        ST_RMW_READ: begin
          if (dec_sbiterr) sbe_o <= 1'b1;

          if (dec_dbiterr) begin
            // Aborta RMW ante DBE previo para no enmascarar corrupción en DMEM
            dbe_o   <= 1'b1;
            ready_o <= 1'b1;
            state   <= ST_IDLE;
          end else begin
            // Si hubo SBE en bytes intactos, rmw_base_q ya entra corregido antes de mezclar
            rmw_base_q <= dec_data;
            state      <= ST_RMW_WRITE;
          end
        end

        ST_RMW_WRITE: begin
          // u_bram ya grabó los 39b mezclados y recodificados en este flanco
          ready_o <= 1'b1;
          state   <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
