// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       ecc_secded.v
// Descripción:  Codificador y decodificador Hsiao SEC-DED (39,32) combinacional
// Reloj/Reset:  Ninguno (lógica puramente combinacional)
// =============================================================================

`timescale 1 ns / 1 ps

// Matriz de paridad Hsiao (39,32): filas balanceadas de 13-14 bits por ecuación.
// Cada bit de datos aporta exactamente 3 unos (peso impar) en su columna vertical,
// garantizando que 32'h0 codifique a 39'h0 (válido tras reset-to-zero en FPGA).
`define HSIAO_P0 32'h00003fff
`define HSIAO_P1 32'h00ffc00f
`define HSIAO_P2 32'h1f03c0f1
`define HSIAO_P3 32'he31c4712
`define HSIAO_P4 32'h6d649924
`define HSIAO_P5 32'hb6a92a40
`define HSIAO_P6 32'hd8d23488

module ecc_secded_enc (
    input  [31:0] data_i,    // Palabra útil de 32 bits
    output [38:0] encoded_o  // Palabra sistemática: [38:32] ECC + [31:0] dato
);
  assign encoded_o[31:0] = data_i;
  // La reducción XOR con máscara constante solo sintetiza cables activos (sin puertas AND reales)
  assign encoded_o[32]   = ^(data_i & `HSIAO_P0);
  assign encoded_o[33]   = ^(data_i & `HSIAO_P1);
  assign encoded_o[34]   = ^(data_i & `HSIAO_P2);
  assign encoded_o[35]   = ^(data_i & `HSIAO_P3);
  assign encoded_o[36]   = ^(data_i & `HSIAO_P4);
  assign encoded_o[37]   = ^(data_i & `HSIAO_P5);
  assign encoded_o[38]   = ^(data_i & `HSIAO_P6);
endmodule

module ecc_secded_dec (
    input  [38:0] encoded_i,  // Palabra de 39 bits leída desde registro/memoria
    output [31:0] data_o,     // Dato de 32 bits (corregido si hay SBE)
    output [ 6:0] ecc_o,      // Paridad de 7 bits corregida (para auto-scrubbing)
    output        sbiterr_o,  // 1'b1 si hay error simple corregible (peso de síndrome impar)
    output        dbiterr_o   // 1'b1 si hay error doble incorregible (peso par != 0)
);
  wire [31:0] data_rx = encoded_i[31:0];
  wire [ 6:0] ecc_rx = encoded_i[38:32];

  // Reutiliza el codificador para no duplicar las ecuaciones XOR de la matriz Hsiao
  wire [38:0] reencoded;
  ecc_secded_enc u_reenc (
      .data_i   (data_rx),
      .encoded_o(reencoded)
  );

  // Síndrome: 0 = sin error; peso impar = 1 error (datos o paridad); peso par != 0 = 2 errores
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

  // Despliega en paralelo 32 comparadores de columna (peso 3) + 7 de paridad (peso 1)
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

  // Ante error doble (peso par), ninguna columna coincide -> máscaras a 0 sin falsa corrección
  assign data_o = data_rx ^ data_mask;
  assign ecc_o  = ecc_rx ^ ecc_mask;

endmodule

// Limpia macros locales para evitar colisiones al compilar otros archivos
`undef HSIAO_P0
`undef HSIAO_P1
`undef HSIAO_P2
`undef HSIAO_P3
`undef HSIAO_P4
`undef HSIAO_P5
`undef HSIAO_P6
