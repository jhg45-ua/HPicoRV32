// =============================================================================
// Proyecto:     SHRV32 (Space-Hardened RISC-V 32)
// Módulo:       bram_sp.v
// Descripción:  BRAM single-port síncrona parametrizable (32b wstrb o 39b ECC)
// Reloj/Reset:  clk (flanco de subida) | sin reset en la matriz de memoria
// =============================================================================

module bram_sp #(
    parameter integer       WORDS      = 4096,
    parameter integer       ADDR_BITS  = 12,
    parameter integer       DATA_WIDTH = 32,
    parameter         [0:0] BYTE_WRITE = 1'b1,
    parameter         [0:0] USE_INIT   = 1'b1,
    parameter               INIT_FILE  = "build/firmware.hex"
) (
    input                       clk,    // Reloj del sistema (flanco de subida)
    input                       en,     // Habilitación de acceso (activo alto)
    input      [           3:0] wstrb,  // Máscara por byte (si BYTE_WRITE=1) o |wstrb como WE
    input      [ ADDR_BITS-1:0] addr,   // Dirección de palabra (log2(WORDS) bits)
    input      [DATA_WIDTH-1:0] wdata,  // Dato de escritura (32b o 39b con ECC)
    output reg [DATA_WIDTH-1:0] rdata   // Dato de lectura registrado (latencia de 1 ciclo)
);

  // Matriz de memoria física (infiere RAMB36E1/RAMB18E1 en Artix-7 o LSRAM en PolarFire)
  reg [DATA_WIDTH-1:0] mem[0:WORDS-1];

  // Precarga firmware (con ECC en 39b) si USE_INIT=1, o alinea simulación a 0 como la FPGA
  integer init_idx;
  generate
    if (USE_INIT) begin : gen_init
      initial begin
`ifdef SYNTHESIS
        $readmemh("firmware.hex", mem);
`elsif VIVADO_MEM_INIT
        $readmemh("firmware.hex", mem);
`else
        $readmemh(INIT_FILE, mem);
`endif
      end
    end else begin : gen_zero_init
      initial begin
        for (init_idx = 0; init_idx < WORDS; init_idx = init_idx + 1)
        mem[init_idx] = {DATA_WIDTH{1'b0}};
      end
    end
  endgenerate

  // Lectura/escritura síncrona obligatoria para inferir BRAM física (no LUTRAM)
  always @(posedge clk) begin
    if (en) begin
      if (BYTE_WRITE && (DATA_WIDTH == 32)) begin
        // Escritura selectiva por byte en modo no-ECC (32b)
        if (wstrb[0]) mem[addr][7:0] <= wdata[7:0];
        if (wstrb[1]) mem[addr][15:8] <= wdata[15:8];
        if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];
        if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];
      end else begin
        // Escritura atómica de palabra completa (necesaria en modo ECC de 39b)
        if (|wstrb) mem[addr] <= wdata;
      end
      rdata <= mem[addr];
    end
  end
endmodule
