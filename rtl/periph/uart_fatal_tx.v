// =============================================================================
// Proyecto:     HPicoRV32 (Hardened PicoRV32)
// Módulo:       uart_fatal_tx.v
// Descripción:  Emisor UART hardware de emergencia para fallos fatales (Hard-Trap)
// Reloj/Reset:  clk (flanco subida) | resetn (activo bajo)
// =============================================================================

`timescale 1 ns / 1 ps

module uart_fatal_tx #(
    parameter integer PREFIX_LEN = 32,
    parameter [8*PREFIX_LEN-1:0] PREFIX_STR = "[HPicoRV32 FATAL] "
) (
    input         clk,
    input         resetn,
    input         start_i,      // Pulso de 1 ciclo para iniciar la transmisión
    input  [ 3:0] cause_i,      // Código de causa (1..8)
    input  [31:0] epc_i,        // Dirección PC/IMEM donde ocurrió el fallo
    input         uart_wait_i,  // Señal reg_dat_wait desde simpleuart
    output        uart_we_o,    // Strobe reg_dat_we hacia simpleuart
    output [ 7:0] uart_data_o,  // Carácter ASCII hacia simpleuart.reg_dat_di[7:0]
    output        busy_o        // 1 mientras la FSM controla la UART
);

  localparam S_IDLE = 1'b0;
  localparam S_SEND = 1'b1;

  localparam integer SUFFIX_START = 2 + PREFIX_LEN;  // Tras "\r\n" + PREFIX_STR
  localparam integer SUFFIX_LEN = 29;  // "CAUSE=0000000X EPC=YYYYYYYY\r\n"
  localparam integer LAST_IDX = SUFFIX_START + SUFFIX_LEN - 1;

  reg state;
  reg [7:0] idx;
  reg [3:0] cause_r;
  reg [31:0] epc_r;

  // Traductor combinacional de 4 bits (nibble) a carácter ASCII '0'..'9','A'..'F'
  function [7:0] hex2ascii;
    input [3:0] nibble;
    begin
      case (nibble)
        4'h0: hex2ascii = "0";
        4'h1: hex2ascii = "1";
        4'h2: hex2ascii = "2";
        4'h3: hex2ascii = "3";
        4'h4: hex2ascii = "4";
        4'h5: hex2ascii = "5";
        4'h6: hex2ascii = "6";
        4'h7: hex2ascii = "7";
        4'h8: hex2ascii = "8";
        4'h9: hex2ascii = "9";
        4'hA: hex2ascii = "A";
        4'hB: hex2ascii = "B";
        4'hC: hex2ascii = "C";
        4'hD: hex2ascii = "D";
        4'hE: hex2ascii = "E";
        4'hF: hex2ascii = "F";
      endcase
    end
  endfunction

  reg [7:0] cur_byte;
  reg [7:0] prefix_pos;
  reg [7:0] suffix_idx;

  always @(*) begin
    prefix_pos = 8'd0;
    suffix_idx = 8'd0;
    cur_byte   = 8'h00;

    if (idx == 8'd0) begin
      cur_byte = 8'h0d;  // '\r'
    end else if (idx == 8'd1) begin
      cur_byte = 8'h0a;  // '\n'
    end else if (idx < SUFFIX_START[7:0]) begin
      // Recorre PREFIX_STR desde el byte más significativo (MSB) al menos significativo (LSB)
      prefix_pos = PREFIX_LEN[7:0] + 8'd1 - idx;
      cur_byte   = PREFIX_STR[8*prefix_pos+:8];
    end else begin
      suffix_idx = idx - SUFFIX_START[7:0];
      case (suffix_idx)
        8'd0: cur_byte = "C";
        8'd1: cur_byte = "A";
        8'd2: cur_byte = "U";
        8'd3: cur_byte = "S";
        8'd4: cur_byte = "E";
        8'd5: cur_byte = "=";
        8'd6: cur_byte = "0";
        8'd7: cur_byte = "0";
        8'd8: cur_byte = "0";
        8'd9: cur_byte = "0";
        8'd10: cur_byte = "0";
        8'd11: cur_byte = "0";
        8'd12: cur_byte = "0";
        8'd13: cur_byte = hex2ascii(cause_r);
        8'd14: cur_byte = " ";
        8'd15: cur_byte = "E";
        8'd16: cur_byte = "P";
        8'd17: cur_byte = "C";
        8'd18: cur_byte = "=";
        8'd19: cur_byte = hex2ascii(epc_r[31:28]);
        8'd20: cur_byte = hex2ascii(epc_r[27:24]);
        8'd21: cur_byte = hex2ascii(epc_r[23:20]);
        8'd22: cur_byte = hex2ascii(epc_r[19:16]);
        8'd23: cur_byte = hex2ascii(epc_r[15:12]);
        8'd24: cur_byte = hex2ascii(epc_r[11:8]);
        8'd25: cur_byte = hex2ascii(epc_r[7:4]);
        8'd26: cur_byte = hex2ascii(epc_r[3:0]);
        8'd27: cur_byte = 8'h0d;  // '\r'
        8'd28: cur_byte = 8'h0a;  // '\n'
        default: cur_byte = 8'h00;
      endcase
    end
  end

  // Salidas derivadas únicamente de FFs (nunca de uart_wait_i) -> cero lazos combinacionales
  assign busy_o      = (state == S_SEND);
  assign uart_data_o = cur_byte;
  assign uart_we_o   = (state == S_SEND) && (cur_byte != 8'h00);

  always @(posedge clk) begin
    if (!resetn) begin
      state   <= S_IDLE;
      idx     <= 8'd0;
      cause_r <= 4'd0;
      epc_r   <= 32'h0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start_i) begin
            cause_r <= cause_i;
            epc_r   <= epc_i;
            idx     <= 8'd0;
            state   <= S_SEND;
          end
        end
        S_SEND: begin
          // Si es byte de relleno (0x00) avanza en 1 ciclo; si es carácter real,
          // avanza justo en el flanco en que simpleuart lo acepta (uart_wait_i == 0)
          if (cur_byte == 8'h00 || !uart_wait_i) begin
            if (idx == LAST_IDX[7:0]) begin
              state <= S_IDLE;
              idx   <= 8'd0;
            end else begin
              idx <= idx + 8'd1;
            end
          end
        end
        default: ;
      endcase
    end
  end


endmodule
