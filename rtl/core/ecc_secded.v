// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       ecc_secded.v
// Descripción:  Codificador y decodificador Hsiao SEC-DED (39,32) combinacional
// Reloj/Reset:  Ninguno (lógica puramente combinacional)
// =============================================================================

`timescale 1 ns / 1 ps

`define HSIAO_P0 32'h00003fff
`define HSIAO_P1 32'h00ffc00f
`define HSIAO_P2 32'h1f03c0f1
`define HSIAO_P3 32'he31c4712
`define HSIAO_P4 32'h6d649924
`define HSIAO_P5 32'hb6a92a40
`define HSIAO_P6 32'hd8d23488

module ecc_secded_enc (
    input  [31:0] data_i,
    output [38:0] encoded_o
);
  assign encoded_o[31:0] = data_i;
  assign encoded_o[32]   = ^(data_i & `HSIAO_P0);
  assign encoded_o[33]   = ^(data_i & `HSIAO_P1);
  assign encoded_o[34]   = ^(data_i & `HSIAO_P2);
  assign encoded_o[35]   = ^(data_i & `HSIAO_P3);
  assign encoded_o[36]   = ^(data_i & `HSIAO_P4);
  assign encoded_o[37]   = ^(data_i & `HSIAO_P5);
  assign encoded_o[38]   = ^(data_i & `HSIAO_P6);
endmodule

module ecc_secded_dec (
    input  [38:0] encoded_i,
    output [31:0] data_o,
    output [ 6:0] ecc_o,
    output        sbiterr_o,
    output        dbiterr_o
);
  wire [31:0] data_rx = encoded_i[31:0];
  wire [ 6:0] ecc_rx = encoded_i[38:32];

  // Recalcula la paridad esperada a partir del dato recibido
  wire [38:0] reencoded;
  ecc_secded_enc u_reenc (
      .data_i   (data_rx),
      .encoded_o(reencoded)
  );

  // Síndrome: 0 = sin error; != 0 identifica el bit afectado
  wire [6:0] syndrome = ecc_rx ^ reencoded[38:32];
  wire       syn_nonzero = |syndrome;
  wire       syn_odd = ^syndrome;

  assign sbiterr_o = syn_nonzero & syn_odd;
  assign dbiterr_o = syn_nonzero & ~syn_odd;

  localparam [31:0] P0 = `HSIAO_P0;
  localparam [31:0] P1 = `HSIAO_P1;
  localparam [31:0] P2 = `HSIAO_P2;
  localparam [31:0] P3 = `HSIAO_P3;
  localparam [31:0] P4 = `HSIAO_P4;
  localparam [31:0] P5 = `HSIAO_P5;
  localparam [31:0] P6 = `HSIAO_P6;

  wire [31:0] data_mask;
  wire [ 6:0] ecc_mask;

  genvar i;
  generate
    for (i = 0; i < 32; i = i + 1) begin : gen_data_corr
      wire [6:0] col = {P6[i], P5[i], P4[i], P3[i], P2[i], P1[i], P0[i]};
      assign data_mask[i] = (syndrome == col);
    end
    for (i = 0; i < 7; i = i + 1) begin : gen_ecc_corr
      wire [6:0] pcol = (7'b0000001 << i);
      assign ecc_mask[i] = (syndrome == pcol);
    end
  endgenerate

  // Ante error doble (peso par), ninguna columna coincide -> máscaras a 0
  assign data_o = data_rx ^ data_mask;
  assign ecc_o  = ecc_rx ^ ecc_mask;

endmodule

`undef HSIAO_P0
`undef HSIAO_P1
`undef HSIAO_P2
`undef HSIAO_P3
`undef HSIAO_P4
`undef HSIAO_P5
`undef HSIAO_P6
