// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       tmr_voter.v
// Descripción:  Votador mayoritario 2-de-3 combinacional y detector de fallos
// Reloj/Reset:  Ninguno (lógica puramente combinacional)
// =============================================================================

module tmr_voter #(
    parameter integer WIDTH = 32
) (
    input [WIDTH-1:0] r0,  // Replica del registro 0
    input [WIDTH-1:0] r1,  // Replica del registro 1
    input [WIDTH-1:0] r2,  // Replica del registro 2
    output [WIDTH-1:0] voted,  // Salida votada
    output err  // 1'b1 si alguna replica discrepa en algun bit
);
  // Preservar la frontera de la red votada
  (* keep = "true", syn_keep = 1 *)wire [WIDTH-1:0] voted_w;
  (* keep = "true", syn_keep = 1 *)wire [WIDTH-1:0] diff_w;

  // Votador mayoritario 2-de-3
  assign voted_w = (r0 & r1) | (r0 & r2) | (r1 & r2);

  // Mascara de bits que difieren entre las replicas
  assign diff_w  = (r0 ^ r1) | (r0 ^ r2) | (r1 ^ r2);

  assign voted   = voted_w;
  assign err     = |diff_w;

endmodule
