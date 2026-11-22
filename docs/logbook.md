# Bitácora Técnica — HPicoRV32

Registro cronológico de hitos, verificaciones en simulación y métricas reales de implementación (*post-route* en **Vivado** y **openXC7**) en **Digilent Nexys A7-100T** (`xc7a100tcsg324-1`) para comparar la evolución de recursos y frecuencia frente al diseño base.

---

## [2026-10-30] — Inicio del proyecto: SoC base con PicoRV32 y firmware bare-metal

### Objetivo
Levantar un *System-on-Chip* funcional mínimo en la placa **Digilent Nexys A7-100T** (100 MHz) alrededor del núcleo **PicoRV32** (RV32I, bus nativo sin AXI), sin técnicas de endurecimiento frente a radiación, junto con un flujo de firmware bare-metal propio.

### Trabajo realizado (fase inicial en `picorv32-soc`)
- Integración inicial de `picorv32` conectado a memoria BRAM unificada de 16 KB (4096 palabras de 32 bits), periférico UART (`simpleuart` a 115200 baudios, divisor `868`) y registro de 15 LEDs + indicador `trap` en LED15.
- Desarrollo del firmware básico en C/ensamblador RISC-V (`rv32i` / `ilp32`):
  - **Bootloader UART** en `0x0000_0000`: autocomprobación de LEDs y RAM, mensaje `READY` y recepción de binarios hacia `0x0000_0800`.
  - **Aplicación contador**: parpadeo en `leds[14:0]` y envío periódico de latido por puerto serie.
- Primeras pruebas exploratorias de TMR y ECC sobre la base de trabajo antes de planificar una reorganización limpia por ramas.

---

## [2026-11-13] — Hito 0: Transición a `shrv32` y línea base verificada (`feat/baseline-soc`)

### Cambios de arquitectura y organización
- Reestructuración limpia en `shrv32` con submódulos de solo lectura (`external/picorv32`, `external/harv`), separación modular en `rtl/` (`core/`, `mem/`, `periph/`, `top/`), `sw/` unificado y scripts duales para Vivado batch/GUI (`create_project.tcl`, `build.tcl`).
- Extracción de la memoria a [`bram_sp.v`](../rtl/mem/bram_sp.v) (lectura/escritura síncrona con máscara por bytes `wstrb`) y módulo raíz [`soc.v`](../rtl/top/soc.v) (latencia de lectura de 1 ciclo en BRAM mediante mux combinacional sobre `ram_rdata`).
- Adaptación del firmware en `sw/` (`bootloader.elf`: `564` B; `counter.elf`: `600` B) con recompilación automática ante cambios de `FW` o `SIM_FAST`.

### Verificación en simulación y linting
- **Verilator (`make lint`):** superado sin errores (`0` avisos bloqueantes sobre `soc`).
- **Icarus Verilog (`iverilog -g2001` + `vvp` con `tb_soc.v`):** arranque tras *Power-On Reset* (63 ciclos), banner UART completo, contador en LEDs (`0x0001`..`0x0040` con `[SHRV32 Latido] Contador = 0..3` usando `SIM_FAST=1`, y `Contador = 0` con `SIM_FAST=0`) y salida limpia sin `trap`.

### Métricas de implementación en Vivado (`impl_1` — *Post-Route*)
- **Herramienta y dispositivo:** Vivado `v2025.2` (lin64) · `xc7a100tcsg324-1` (`-1`) · Reloj objetivo `sys_clk_pin` = `100.000 MHz` (`10.000 ns`).

| Recurso / Métrica | Usado | Disponible | Utilización | Notas |
| --- | ---: | ---: | ---: | --- |
| **Slice LUTs** | 1114 | 63400 | 1.76 % | 1070 lógica + 44 LUTRAM (`cpuregs`) |
| **Slice Registers (FF)** | 703 | 126800 | 0.55 % | 680 `FDRE` + 23 `FDSE`, 0 latches |
| **Block RAM Tile (`RAMB36E1`)** | 4 | 135 | 2.96 % | 16 KB (`bram_sp`) inferidos como BRAM |
| **DSPs** | 0 | 240 | 0.00 % | RV32I base sin multiplicador hardware |
| **Bonded IOB** | 20 | 210 | 9.52 % | `clk`, `resetn`, `trap`, `leds[14:0]`, UART |
| **BUFGCTRL** | 1 | 32 | 3.13 % | Reloj principal `clk` |

| Parámetro de Timing (`sys_clk_pin` @ 100 MHz) | Valor | Endpoints con fallo | Notas |
| --- | ---: | ---: | --- |
| **WNS (Setup)** | +3.531 ns | 0 / 2267 | $F_{\max}$ estimada $\approx 154.6\text{ MHz}$ |
| **WHS (Hold)** | +0.104 ns | 0 / 2267 | Cumple holgura mínima |
| **WPWS (Pulse Width)** | +3.750 ns | 0 / 796 | Cumple ancho de pulso |

### Observaciones técnicas
- **Camino crítico:** `ram/mem_reg_3/CLKARDCLK` (`RAMB36E1`) $\rightarrow$ 3 niveles de LUT $\rightarrow$ `cpu/reg_out_reg[10]/D` (`6.373 ns` de retardo de datos).
- **Aviso `SYNTH-6` (x4):** Vivado indica que el registro de salida de las `RAMB36E1` no usa una etapa adicional interna (`DOA_REG`), al estar multiplexado directamente hacia la CPU. Con `+3.531 ns` de margen a 100 MHz no supone problema en la línea base, pero conviene tenerlo en cuenta cuando se añada lógica combinacional de decodificación **ECC** en la ruta de lectura.
- **Aviso `TIMING-18` (x19):** Esperable en esta etapa al tratarse de E/S lentas o asíncronas (`resetn`, `leds`, `trap`, `ser_tx`, `ser_rx`) sin restricciones `set_input_delay`/`set_output_delay` en el `.xdc`.
- **Modo proyecto Vivado:** `$readmemh` en `synth_1`/`sim_1` requiere referenciar `"firmware.hex"` por nombre base y marcar el fichero como `Memory Initialization Files` en `create_project.tcl`.

---

## [2026-11-14] — Análisis del core de referencia HARV ([`harv_notes.md`](harv_notes.md))

### Objetivo
Estudiar las técnicas de tolerancia a fallos del submódulo [`external/harv`](../external/harv) (TMR y codificación Hamming SEC-DED) para definir qué patrones adoptar y qué errores evitar antes de iniciar la fase de endurecimiento RTL de SHRV32.

### Trabajo realizado
- Revisión completa del esquema TMR (`control_tmr.vhd`, `alu_tmr.vhd`) y de protección Hamming (`hamming_pkg.vhd`, `hamming_encoder.vhd`, `hamming_decoder.vhd`, `hamming_register.vhd`, `regfile.vhd`, `instr_fetch.vhd`) documentada en [`harv_notes.md`](harv_notes.md).
- Criterios aprovechables para SHRV32:
  - Atributos de síntesis portables entre Vivado (`DONT_TOUCH`) y Synplify/PolarFire (`syn_radhardlevel`, `syn_keep`, `syn_noprune`, `syn_safe_case`).
  - Capa de diagnóstico y telemetría mediante contadores `SBU`/`DBU` y discrepancias TMR habilitados solo en transacciones válidas.
- Carencias y *bugs* de HARV a evitar en SHRV32:
  - TMR "macro" sin *self-healing* en `control_tmr` (el estado votado nunca realimenta `proc_status_r`) y triplicación combinacional costosa en `alu_tmr`.
  - Hamming sin *auto-scrubbing*, banco de registros en flip-flops + `MUXF7` (sin inferir LUTRAM), matriz no balanceada frente a Hsiao (39,32), *bug* de paridad global en `get_parity_data_result` para reset no nulo y registro de configuración `harden_conf_r` sin reset ni protección (SPOF).

### Decisiones de diseño para siguientes hitos
- Mantener la ejecución multiciclo de `picorv32` aplicando TMR selectivo con realimentación (*self-healing*) sobre registros críticos (`reg_pc`, estados de control).
- Implementar ECC mediante código **Hsiao SEC-DED (39,32)** balanceado con *auto-scrubbing* en el banco de registros (preservando LUTRAM) y controlador *Read-Modify-Write* en [`bram_sp.v`](../rtl/mem/bram_sp.v).

---

## [2026-11-15] — Hito 1: TMR selectivo con *self-healing* y telemetría CSR (`feature/tmr`)

### Objetivo
Implementar Triple Redundancia Modular (TMR) de grano fino con corrección síncrona en 1 ciclo (*self-healing*) sobre el camino de PC y registros críticos de control de `picorv32`, exponiendo contadores de fallos en CSRs de solo lectura y validando mediante inyección de SEUs por máscaras XOR e implementación en Vivado.

### Cambios realizados
- **Votador combinacional reutilizable ([`tmr_voter.v`](../rtl/core/tmr_voter.v)):** votador 2-de-3 parametrizado por ancho (`WIDTH`) con detección simétrica de discrepancia (`err`) y atributos de preservación (`keep`, `syn_keep`) frente a optimizaciones de síntesis.
- **Protección de dominio PC y control en [`picorv32.v`](../rtl/core/picorv32.v) (controlado por `ENABLE_TMR`, activo en [`soc.v`](../rtl/top/soc.v)):**
  - Triplicación con `dont_touch` / `syn_preserve` sobre `reg_pc`, `reg_next_pc` (32 bits), `cpu_state` (8 bits), `mem_state` (2 bits) y `latched_rd` (`regindex_bits` bits), además de reset explícito de `decoded_rd` y `latched_rd` para evitar propagación de `X` al votador.
  - Patrón *self-healing* sin condiciones de carrera dentro del mismo `always @(posedge clk)`: inicialización por defecto `next_<reg> = <voted>` al comienzo del ciclo y escritura simultánea en `_r0/_r1/_r2 <= next_<reg>` al final.
- **Telemetría CSR y soporte en firmware:**
  - Nuevos CSRs custom User R/O (`0xCC0` $\rightarrow$ `count_tmr_pc`, `0xCC1` $\rightarrow$ `count_tmr_ctrl`) en [`picorv32.v`](../rtl/core/picorv32.v) muestreados síncronamente en el flanco previo a la reparación por *self-healing*.
  - Lectura mediante `.option push / .option arch, +zicsr / csrr / .option pop` + `puthex()` en [`io.h`](../sw/common/io.h) (conservando `-march=rv32i` estricto en el resto del firmware) e impresión en el latido UART de [`main.c`](../sw/apps/counter/main.c) (`counter.elf`: `728` B; `bootloader.elf`: `564` B).

### Verificación en simulación y linting
- **Test unitario ([`tb_tmr_voter.v`](../tb/tb_tmr_voter.v)):** 5/5 pruebas superadas (`make sim TB=tb/tb_tmr_voter.v`) incluyendo fallo de 1 bit, multi-bit en una réplica, bits disjuntos en múltiples réplicas y límite 2-de-3 en el mismo bit.
- **Test SoC con inyección SEU ([`tb_soc.v`](../tb/tb_soc.v)):** `make sim SIM_FAST=1` superado sin `trap` hasta `50 ms` (`LEDs = 0x0060`):
  - Buffer de línea UART para evitar solapamientos con el monitor de LEDs.
  - Campaña de 7 inyecciones XOR (`inject_pc_seu` x3 sobre `reg_pc_r0`, `reg_pc_r1` multi-bit y `reg_next_pc_r1`; `inject_ctrl_seu` x4 sobre `cpu_state_r0`, `cpu_state_r2`, `mem_state_r1` y `latched_rd_r0`), verificando enmascaramiento inmediato, *self-healing* en `10 ns` (`1` ciclo) y lectura exacta por UART (`PC=00000003 CTRL=00000004` en `Contador = 1..5`).
- **Verilator (`make lint`):** superado sin avisos en macOS (`Verilator 5.054`). En Linux Workstation (`Verilator 5.036`) falla por flag desconocido `-Wno-PROCASSINIT` en el `Makefile` (pendiente de filtrar según versión).

### Métricas de implementación en Vivado (`impl_1` — *Post-Route*)
- **Herramienta y dispositivo:** Vivado `v2025.2` (lin64) · `xc7a100tcsg324-1` (`-1`) · Reloj objetivo `sys_clk_pin` = `100.000 MHz` (`10.000 ns`).

| Recurso / Métrica | Usado | Disponible | Utilización | Variación vs. base |
| --- | ---: | ---: | ---: | --- |
| **Slice LUTs** | 1429 | 63400 | 2.25 % | `+315` (+28.3 % · `1385` lógica + `44` LUTRAM) |
| **Slice Registers (FF)** | 936 | 126800 | 0.74 % | `+233` (+33.1 % · `914` `FDRE` + `22` `FDSE`, `0` latches) |
| **Block RAM Tile (`RAMB36E1`)** | 4 | 135 | 2.96 % | `0` (sin cambios) |
| **DSPs** | 0 | 240 | 0.00 % | `0` (sin cambios) |
| **Bonded IOB** | 20 | 210 | 9.52 % | `0` (sin cambios) |
| **BUFGCTRL** | 1 | 32 | 3.13 % | `0` (sin cambios) |

| Parámetro de Timing (`sys_clk_pin` @ 100 MHz) | Valor | Endpoints con fallo | Notas |
| --- | ---: | ---: | --- |
| **WNS (Setup)** | +2.298 ns | 0 / 2691 | $F_{\max}$ estimada $\approx 129.8\text{ MHz}$ (`-1.233 ns` vs. base) |
| **WHS (Hold)** | +0.110 ns | 0 / 2691 | Cumple holgura mínima |
| **WPWS (Pulse Width)** | +3.750 ns | 0 / 1029 | Cumple ancho de pulso |

### Observaciones técnicas
- **Preservación real de las 3 réplicas:** el incremento de `+233` FFs (`+158` FFs de réplicas redundantes + `64` FFs de `count_tmr_pc`/`count_tmr_ctrl` + registros de decodificación/fanout) y la presencia explícita de `cpu/gen_tmr_pc.u_voter_next_pc/` y `cpu/reg_next_pc_r0_reg[28]` en `timing.rpt` confirman que `dont_touch` impidió la fusión booleana en Vivado.
- **Camino crítico:** `cpu/latched_branch_reg/C` (`FDRE`) $\rightarrow$ `cpu/gen_tmr_pc.u_voter_next_pc/` (`LUT6` + 5 `CARRY4` + `LUT3`, 7 niveles lógicos) $\rightarrow$ `cpu/reg_next_pc_r0_reg[28]/D` (`7.272 ns` de retardo de datos: `2.095 ns` lógica, `5.177 ns` ruta).
- **Avisos de Vivado:** mismos avisos no bloqueantes que en el Hito 0 (`SYNTH-6` x4 en BRAM y `TIMING-18` x19 en E/S sin restricciones).

---

## [2026-11-15] — Flujo abierto `openXC7` y preservación de TMR en Yosys (`build/openxc7`)

### Objetivo
Integrar un flujo de síntesis, *place & route*, generación de *bitstream* y programación completamente *open source* con **openXC7** (`SYNTH=openxc7`) en macOS nativo para la **Digilent Nexys A7-100T**, asegurando que **Yosys** conserve físicamente las réplicas TMR sin introducir primitivas propietarias en `rtl/core/`.

### Cambios realizados
- **Integración dual en [`Makefile`](../Makefile):**
  - Añadidas variables `SYNTH ?= vivado`, `OPENXC7_DIR` (`build/openxc7`) y `CHIPDB_DIR` (`$(HOME)/.cache/openxc7`), seleccionando el `.bit` objetivo también en `make prog`.
  - Generación bajo demanda del `chipdb-xc7a100tcsg324-1.bin` (`xilinx_gen.py` + `bbasm`) e implementación mediante `yosys` $\rightarrow$ `nextpnr-xilinx` $\rightarrow$ `fasm2frames` $\rightarrow$ `xc7frames2bit`.
- **Compatibilidad del fichero de restricciones ([`Nexys-A7-100T-Master.xdc`](../fpga/nexys_a7/Nexys-A7-100T-Master.xdc)):** limpieza de espacios dentro de `{puerto}`, `;` finales y comentarios en la misma línea (manteniendo compatibilidad con Vivado y el parser XDC de `nextpnr-xilinx`).
- **Preservación de TMR en Yosys ([`picorv32.v`](../rtl/core/picorv32.v) + [`Makefile`](../Makefile)):**
  - Añadido `keep = "true"` junto a `dont_touch = "true", syn_preserve = 1` en las 5 declaraciones `reg` TMR (`reg_pc_r0..r2`, `reg_next_pc_r0..r2`, `mem_state_r0..r2`, `cpu_state_r0..r2`, `latched_rd_r0..r2`).
  - Propagación explícita del atributo tras `proc` antes de `synth_xilinx`: `hierarchy -check -top soc; proc; setattr -set keep 1 a:keep %ci1 t:*dff* %i; synth_xilinx -flatten -abc9 -arch xc7 -top soc; write_json soc.json`.

### Verificación en simulación, linting y placa
- **Lint (`make lint`):** superado sin errores (`Verilator 5.054`).
- **Simulación:** validados tanto el banco unitario ([`tb_tmr_voter.v`](../tb/tb_tmr_voter.v), `5/5` casos `[PASS]`) como la campaña SEU en [`tb_soc.v`](../tb/tb_soc.v) (`make sim SIM_FAST=1`).
- **Validación en placa real:** generación de `build/openxc7/shrv32.bit` (`3825904` bytes) y programación correcta en la Nexys A7-100T mediante `make prog SYNTH=openxc7` (`openFPGALoader`), confirmando arranque, LEDs y telemetría UART sin fallos.

### Métricas de implementación en openXC7 (`nextpnr-xilinx` — *Post-Route*)
- **Herramientas y dispositivo:** `Yosys 0.69` + `nextpnr-xilinx` (`himbaechel`) + `fasm2frames` + `xc7frames2bit` (`/opt/openxc7`) · `xc7a100tcsg324-1` · Reloj `clk` = `100.000 MHz` (`10.000 ns`).

| Recurso / Métrica | Usado | Disponible | Utilización | Notas / Comparativa |
| --- | ---: | ---: | ---: | --- |
| **Primitivas LUT (Yosys)** | 1767 | — | — | `255 LUT2` + `388 LUT3` + `214 LUT4` + `634 LUT5` + `276 LUT6` (+ `12 RAM32M`, `126 CARRY4`) |
| **`SLICE_LUTX` (`nextpnr`)** | 2671 | 126800 | 2 % | Conteo interno de sitios en `nextpnr-xilinx` |
| **`SLICE_FFX` / FFs totales** | 918 | 126800 | 0 % | `904 FDRE` + `14 FDSE` (vs. `695` FFs antes del arreglo de `keep` y `936` FFs en Vivado Hito 1) |
| **Block RAM Tile (`RAMB36E1`)** | 4 | 135 | 2 % | `0 / 270 RAMB18E1` (16 KB `bram_sp`, igual que Vivado) |
| **$F_{\max}$ (`cpu.clk` @ 100 MHz)** | 135.96 MHz | — | PASS | `3 warnings, 0 errors` (vs. $\approx 129.8\text{ MHz}$ en Vivado Hito 1) |

### Observaciones técnicas
- **Por qué `keep` en `reg` no bastaba en Yosys:** durante `proc_dff`, Yosys hereda atributos desde el bloque `always`, no desde las declaraciones `reg`; y `opt_merge` solo protege biestables si la **celda** FF tiene `keep`. Antes de propagar el atributo mediante `setattr -set keep 1 a:keep %ci1 t:*dff* %i`, Yosys colapsaba las réplicas `_r0/_r1/_r2` reduciendo el diseño a `695` FFs. Etiquetar el `always` principal habría impedido podar registros de depuración sin uso (`dbg_rs1val`, `dbg_rs2val`); la selección tras `proc` conserva exclusivamente los FFs TMR manteniendo `dead_ffs = 0` y *fanout* idéntico entre réplicas en `soc.json` (`reg_pc`: `32x3`, `67/67/67`; `reg_next_pc`: `32x3`, `75/75/75`; `cpu_state`: `8x3`, `21/21/21`; `latched_rd`: `5x3`, `10/10/10`; `mem_state`: `2x3`, `4/4/4`).
- **Generador de bitstream (`xc7frames2bit` vs `fpga-as`):** en pruebas iniciales con `fpga-as` en macOS el bitstream declaraba longitud `0` en cabecera (`'e'`) y omitía el ECC por *frame*, provocando `Done 0x0` en `openFPGALoader`. El cambio a `fasm2frames` + `xc7frames2bit` genera una cabecera `'e'` exacta (`3825788` bytes de payload) y carga limpiamente en la placa.

---

## [2026-11-15] — Integración de Verilator como simulador RTL (`build/verilator-sim`)

### Objetivo
Incorporar **Verilator** (`--binary` con soporte `--timing`) en el [`Makefile`](../Makefile) como alternativa de alta velocidad frente a Icarus Verilog reutilizando directamente los mismos *testbenches* Verilog, manteniendo `iverilog` como simulador por defecto.

### Cambios realizados
- Selector `SIM ?= iverilog` (`iverilog` | `verilator`) en `make sim`, generando el ejecutable de Verilator en `build/vlt_$(TB_TOP)` mediante `--Mdir` y `--top-module $(TB_TOP)` (`TB_TOP ?= $(basename $(notdir $(TB)))`).
- Flag `TRACE ?= 1` para habilitar (`--trace` $\rightarrow$ `build/dump.vcd`) o desactivar (`TRACE=0`) el volcado de ondas.
- Centralización de las supresiones de avisos en `VLT_WARN_FLAGS`, compartida entre `make lint` y `make sim SIM=verilator` (necesaria para puertos de traza sin conectar de `picorv32` en [`soc.v`](../rtl/top/soc.v) y extensiones/truncamientos implícitos de ancho en [`simpleuart.v`](../rtl/periph/simpleuart.v)).

### Verificación y comparativa de rendimiento (`tb_soc.v` base, 30 ms / 3M ciclos)
- **Herramienta:** Verilator `5.054` (compilación C++ paralela con `-j 0`).
- **Simulación funcional (`make sim SIM_FAST=1 SIM=verilator`):** arranque correcto tras POR, banner UART completo, secuencia en LEDs `0x0001`..`0x0040` con `[SHRV32 Latido] Contador = 0..3` y salida limpia por *timeout* sin `trap` (idéntica a Icarus Verilog).
- **Tiempos medidos:**
  - `SIM=verilator TRACE=1`: `1.377 s` de simulación (*walltime*; `1.616 s` en la prueba previa) frente a `~51 s` en `vvp` generando el mismo `build/dump.vcd` (`833 MB`).
  - `SIM=verilator TRACE=0`: `0.666 s` de simulación al omitir la escritura en disco del VCD.
- **Linting (`make lint`):** superado sin errores (`0.039 s`).

### Observaciones técnicas
- **Simulador de 2 estados vs. 4 estados:** Verilator no modela `X` ni `Z` (inicializa los registros a `0` por defecto), por lo que puede ocultar fallos de *reset* o lecturas de memoria no inicializadas que `iverilog` (4 estados) y Vivado sí exponen. Se mantiene `iverilog` como referencia por defecto y Verilator para iteración rápida y futuras campañas largas de inyección de fallos SEU.
- **Simulación monohilo (`1` hilo) frente a `--threads`:** aunque `-j 0` paraleliza la compilación C++ (`10` hilos), las pruebas con `--threads 4` (`5.386 s` *walltime* con `--trace`) y `--threads 10` (`3.289 s` *walltime* sin `--trace`) resultaron ~4–5× más lentas que en 1 hilo debido al sobrecoste de sincronización entre hilos en cada flanco de reloj sobre un SoC pequeño (~1114 LUTs / 703 FFs). Se mantiene la simulación monohilo salvo que el diseño escale significativamente en futuros hitos.

---

## [2026-11-15] — Separación de memoria Harvard: IMEM / DMEM (`feature/harvard-mem`)

Primer paso preparatorio para el endurecimiento con ECC (basado en el análisis de HARV en `docs/harv_notes.md`): división de la BRAM unificada de 16 KB (`4096 × 32 bits`) en dos memorias independientes con separación estricta *Write XOR Execute* (`W^X`) por bus.

### Arquitectura y cambios implementados
- **Mapa de memoria Harvard en [`soc.v`](../rtl/top/soc.v):**
  - **IMEM (`0x0000_0000 – 0x0000_1FFF`, 8 KB, 2048 palabras):** instanciación de `bram_sp` con `USE_INIT = 1'b1` (precarga de `firmware.hex`), puerto de escritura fijado en hardware a `wstrb = 4'b0000` y `wdata = 32'h0`. Admite *fetches* de instrucciones (`mem_instr == 1`) y lecturas de solo lectura (`!(|mem_wstrb)`) para acceder a `.rodata`/`.srodata` (cadenas UART).
  - **DMEM (`0x0000_2000 – 0x0000_3FFF`, 8 KB, 2048 palabras):** instanciación de `bram_sp` con `USE_INIT = 1'b0` (sin carga inicial en síntesis/simulación, preparada para futura migración a IP ECC sin `.coe`). Acceso exclusivo a lectura/escritura de datos (`!mem_instr`).
  - **Protección `W^X` (`harv_err` $\rightarrow$ `trap`):** cualquier escritura hacia IMEM o *fetch* de instrucción en DMEM activa `harv_err`, engancha `harv_fault_r` (conectado a `trap = cpu_trap | harv_fault_r`) y responde `mem_ready = 1` en el ciclo siguiente para evitar bloqueos del bus.
- **[`bram_sp.v`](../rtl/mem/bram_sp.v):** incorporación del parámetro `parameter [0:0] USE_INIT = 1'b1` envolviendo el bloque `initial $readmemh(...)` dentro de `generate if (USE_INIT)`.
- **Toolchain software ([`sections.ld`](../sw/boot/sections.ld), [`crt0.S`](../sw/boot/crt0.S), [`sw/Makefile`](../sw/Makefile), [`Makefile`](../Makefile)):**
  - Definición explícita de regiones `IMEM (rx)` (`0x00000000`, 8K) y `DMEM (rw)` (`0x00002000`, 8K), con `.data : AT(_etext)` para copiar datos inicializados desde IMEM a DMEM en el arranque (`crt0.S`), inicialización de `.bss` a cero y `_estack = 0x00004000`.
  - Parametrización completa de `APP` (`counter` por defecto) y `SIM_FAST`, ajustando `MEM_WORDS := 2048` en `makehex.py` (imagen de 8 KB).

### Verificación funcional (`iverilog` / `verilator`)
- `make lint` (`Verilator 5.054`): `0` errores y `0` *warnings* en 14 módulos RTL (`0.042 s`).
- `make sim SIM_FAST=1 SIM=iverilog` y `make sim SIM_FAST=1 SIM=verilator`:
  - Compilación del *firmware* `counter` (`text=684`, `data=0`, `bss=0`, binario `684 B` en `SIM_FAST=1`; `688 B` en `SIM_FAST=0`).
  - Ejecución completa en ambos simuladores: *banner* UART, **7/7** inyecciones SEU superadas (`PC target=0/1/4` $\rightarrow$ `count_tmr_pc=3`; `CTRL target=0/2/4/6` $\rightarrow$ `count_tmr_ctrl=4`), 6 latidos (`Contador = 0..5`) y finalización limpia por *timeout* (`50 ms`) sin `trap`.
  - Inspección de trazas en `build/dump.vcd`: conmutación correcta de `dmem_sel` en accesos a pila y `harv_err == 0` en toda la ejecución.

### Resultados de síntesis y P&R (`openXC7` — `xc7a100tcsg324-1`)
Flujo ejecutado con `make synth SYNTH=openxc7` (`Yosys 0.69` + `nextpnr-xilinx` + `fasm2frames` + `xc7frames2bit`) y validado físicamente en la placa **Digilent Nexys A7-100T**:

| Recurso / Métrica | Unificada (baseline openXC7) | Harvard IMEM+DMEM | Delta |
| :--- | :---: | :---: | :---: |
| **Yosys Logic LUTs (LUT2–LUT6)** | `1767` | `1772` (`260 LUT2`, `370 LUT3`, `234 LUT4`, `620 LUT5`, `288 LUT6`) | `+5` |
| **Post-route `SLICE_LUTX`** | `2671` | `2684 / 126800` (`2%`) | `+13` |
| **Flip-Flops (`SLICE_FFX`)** | `918` | `921 / 126800` (`0%` — `907 FDRE`, `14 FDSE`) | `+3` |
| **LUTRAM (`RAM32M` / `cpuregs`)** | `12` | `12` | `0` |
| **Carry chains (`CARRY4`)** | `126` (Yosys) | `128` (Yosys) / `131 / 15850` (`nextpnr`, `0%`) | `+2` (Yosys) |
| **Block RAM (`RAMB36E1`)** | `4` | `4 / 135` (`2%` — `2` IMEM + `2` DMEM) | `0` |
| **Frecuencia máx. (`cpu.clk`)** | `135.96 MHz` | `131.58 MHz` (`PASS` @ `100.00 MHz`) | `-4.38 MHz` |
| **Camino crítico** | — | `7.60 ns` (`2.28 ns` lógica + `5.32 ns` ruta) | — |

### Observaciones técnicas
- **Cero sobrecoste en BRAM (`4 RAMB36E1`):** dividir la memoria de `4096 × 32b` en dos bancos independientes de `2048 × 32b` mantiene el mismo consumo exacto de bloques físicos (`imem.mem.0.0/0.1` inicializadas y `dmem.mem.0.0/0.1` sin inicializar), ya que cada `RAMB36E1` en profundidad `2048` opera con ancho nativo de hasta 18 bits (`2 × 2048 × 16b` útiles por banco).
- **Sobrecoste mínimo en lógica:** los `+3` flip-flops adicionales corresponden exactamente a los registros de decodificación de respuesta (`imem_read_r`, `dmem_read_r`) y al *latch* de fallo Harvard (`harv_fault_r`).
- **Camino crítico:** continúa acotado dentro de PicoRV32 (`cpu.latched_branch` $\rightarrow$ `next_reg_next_pc[31:0][26]`) con `2.40 ns` de *slack* positivo frente al requisito de `10.00 ns` (`100 MHz`).
- **Nota pendiente (Fase 2 ECC):** los comentarios iniciales de [`bram_sp.v`](../rtl/mem/bram_sp.v) todavía mencionan `16 KB (4096 palabras)`; conviene actualizarlos al introducir el controlador ECC de memoria.

---

## [2026-11-16] — Hito 2: Protección ECC SEC-DED en registros y memorias Harvard (`feature/ecc-mem`)

### Objetivo
Endurecer los elementos de almacenamiento del SoC (**banco de registros `cpuregs`**, **IMEM de 8 KB** y **DMEM de 8 KB**) frente a *Single Event Upsets* (SEU) mediante códigos **SEC-DED (39,32)** con **auto-scrubbing** hardware de errores simples (`SBE`), parada segura (`trap`) ante errores dobles incorregibles (`DBE`), soporte *Read-Modify-Write* (`RMW`) para escrituras parciales (`sb`/`sh`) y telemetría dedicada por CSR y MMIO, manteniendo compatibilidad dual entre el flujo RTL portable (`iverilog`, `Verilator`, `openXC7`, PolarFire) y la IP oficial **Block Memory Generator (`blk_mem_gen` v8.4)** con *Soft ECC* en Vivado.

### Arquitectura y cambios implementados

1. **Códec combinacional Hsiao SEC-DED (39,32) ([`ecc_secded.v`](../rtl/core/ecc_secded.v)):**
   - Matriz de paridad **Hsiao (39,32)** sistemática (`[38:32]` paridad + `[31:0]` datos) con ecuaciones balanceadas de 13–14 entradas XOR por fila (`HSIAO_P0..P6`), reduciendo la profundidad lógica frente a Hamming clásico.
   - Cada columna de datos tiene peso impar exacto (`3` unos), garantizando que la palabra nula `32'h0000_0000` codifique a `39'h0` (estado inicial válido tras *reset-to-zero* en FPGA sin falsos errores).
   - `ecc_secded_dec` reutiliza `ecc_secded_enc` para calcular el síndrome de 7 bits (`sbiterr_o` si síndrome $\neq 0$ con peso impar; `dbiterr_o` si síndrome $\neq 0$ con peso par) y corrige tanto los 32 bits de datos (`data_o`) como los 7 bits de paridad (`ecc_o`) para permitir *auto-scrubbing* completo.

2. **Banco de registros `cpuregs` de 39 bits con *auto-scrubbing* oportunista ([`picorv32.v`](../rtl/core/picorv32.v)):**
   - Ampliación de `cpuregs` a `32 × 39` bits bajo `ENABLE_ECC = 1`, preservando un único puerto de escritura síncrono y dos puertos de lectura asíncronos para seguir infiriendo **LUTRAM (`14 × RAM32M`)** en lugar de flip-flops.
   - Un codificador `u_enc_cpuregs` en la ruta de *write-back* y dos decodificadores combinacionales (`u_dec_rs1`, `u_dec_rs2`) en las salidas de lectura.
   - **Auto-scrubbing en 1 ciclo sin penalización de CPI:** cuando la CPU no escribe en `rd` (`!cpuregs_cpu_wen`), si `rs1` o `rs2` presentan `sbiterr`, se reescribe la palabra reparada de 39 bits (`{cpuregs_ecc_fix, cpuregs_rs_dec}`) en el mismo flanco de reloj (`cpuregs_scrub1` con prioridad sobre `cpuregs_scrub2`).
   - **Supresión de falsos *traps* en lecturas especulativas:** `reg_dbe_event` cualifica los errores dobles con el uso real de `rs1` (`reg_uses_rs1`) y `rs2` (`reg_uses_rs2`) según el tipo de instrucción en `cpu_state_ld_rs1`, evitando *traps* espurios cuando instrucciones tipo I/U/J/CSR decodifican campos `rs1`/`rs2` que no son registros fuente.
   - **Telemetría CSR:** nuevos contadores de solo lectura `CSR_ECC_REG_SBU` (`0xCC2`) y `CSR_ECC_REG_DBU` (`0xCC3`), más transición directa a `cpu_state_trap` ante `reg_dbe_event`.

3. **Controlador ECC de memoria BRAM con *scrubbing*, RMW y backend dual ([`bram_ecc.v`](../rtl/mem/bram_ecc.v), [`bram_sp.v`](../rtl/mem/bram_sp.v)):**
   - Parametrización de [`bram_sp.v`](../rtl/mem/bram_sp.v) con `DATA_WIDTH` (`32`/`39`), `BYTE_WRITE` (`0` = escritura atómica de palabra completa) e inicialización a cero en simulación (`gen_zero_init` cuando `USE_INIT = 0`) para alinear simuladores de 4 estados (`iverilog`) con el arranque físico de las BRAM en FPGA.
   - Máquina de estados en [`bram_ecc.v`](../rtl/mem/bram_ecc.v) (`ST_IDLE`, `ST_READ`, `ST_SCRUB`, `ST_RMW_READ`, `ST_RMW_WRITE`) con registro de salida `rdata_o` que corta la ruta combinacional entre la BRAM, el decodificador ECC y el núcleo:
     - `sw` (`wstrb = 4'b1111`): codificación y escritura directa en **1 ciclo**.
     - `lw` (`wstrb = 4'b0000`): lectura síncrona + decodificación y registro en **2 ciclos** (**3 ciclos** si detecta `SBE` y ejecuta `ST_SCRUB` reescribiendo `scrub_word_q`). En `IMEM` (`READ_ONLY = 1'b1`), las escrituras desde el bus quedan bloqueadas, pero `ST_SCRUB` sí repara internamente la BRAM ante un `SBE`.
     - `sb`/`sh` parciales (`0 < wstrb < 4'b1111`): secuencia *Read-Modify-Write* de **3 ciclos** (`ST_RMW_READ` $\rightarrow$ `ST_RMW_WRITE`), reparando al vuelo cualquier `SBE` previo en la palabra base antes de mezclar los bytes nuevos, y **abortando la escritura** si detecta un `DBE` previo para no enmascarar corrupción con paridad nueva válida.
   - **Backend dual (`VIVADO_ECC_IP`):**
     - Por defecto (`iverilog`, `Verilator`, `openXC7`, `sim_1` en Vivado y banco `imem`): usa `bram_sp` de 39 bits + `ecc_secded_enc`/`ecc_secded_dec`.
     - En síntesis de Vivado (`sources_1` con `VIVADO_ECC_IP=1` en [`create_project.tcl`](../fpga/nexys_a7/create_project.tcl)): `dmem` instancia la IP oficial `blk_mem_gen_dmem_ecc` (*Simple Dual-Port RAM*, `2048 × 32`, `CONFIG.ECC {false}`, `CONFIG.ecctype {Soft_ECC}`, `CONFIG.softecc {true}` $\rightarrow$ `C_USE_SOFTECC = 1, C_USE_ECC = 0`), manteniendo nuestra FSM de RMW y *auto-scrubbing* por encima de la IP.

4. **Integración en [`soc.v`](../rtl/top/soc.v) y toolchain de firmware ([`makehex.py`](../sw/common/makehex.py), [`io.h`](../sw/common/io.h), [`main.c`](../sw/apps/counter/main.c)):**
   - Generación de imágenes de 39 bits (`10` dígitos hexadecimales por línea) mediante `python3 common/makehex.py ... 2048 --ecc` en [`sw/Makefile`](../sw/Makefile).
   - Contadores MMIO de telemetría de memoria en `0x3000_0000..0x3000_000C` (`REG_ECC_IMEM_SBU`, `REG_ECC_IMEM_DBU`, `REG_ECC_DMEM_SBU`, `REG_ECC_DMEM_DBU`), bloqueo de escrituras y activación de `ecc_fault_r` ($\rightarrow$ `trap`) ante cualquier `DBE` en IMEM o DMEM.
   - Ampliación del latido UART en [`main.c`](../sw/apps/counter/main.c) (`counter.elf`: `904` B `.text` con `SIM_FAST=0`, `900` B con `SIM_FAST=1`, más `4` B `.data` y `4` B `.bss`) ejercitando variables en `.data`/`.bss` con accesos `lw`/`sw` y `sb` (RMW) e imprimiendo `PC`, `CTRL`, `SBU`, `DBU`, `ISBU`, `IDBU`, `DSBU` y `DDBU`.

### Verificación en simulación y linting
- **Verilator (`make lint`):** `0` errores y `0` avisos bloqueantes tanto en modo RTL por defecto como con `-DVIVADO_ECC_IP=1` (usando *stub* de `blk_mem_gen_dmem_ecc`).
- **Test unitario del códec ([`tb_ecc_secded.v`](../tb/tb_ecc_secded.v)):** **5468/5468** comprobaciones superadas en `iverilog` (palabra nula `32'h0 -> 39'h0` + 7 patrones $\times$ `[1 nominal + 39 SBE + 741 DBE]`).
- **Test unitario del controlador BRAM ECC ([`tb_bram_ecc.v`](../tb/tb_bram_ecc.v)):** **6/6** pruebas superadas en `iverilog` y `Verilator` (`sw` 1c / `lw` 2c, `sb`/`sh` RMW 3c incluyendo palabra virgen a `0`, *auto-scrubbing* de SBE en dato y paridad, RMW sobre palabra con SBE previo, detección de DBE + aborto seguro de RMW, y bloqueo de escritura externa con *scrubbing* interno en `READ_ONLY=1`).
- **Test integral del SoC ([`tb_soc.v`](../tb/tb_soc.v)):** campaña completa superada (`make sw SIM_FAST=1`) en `Verilator` (`2.513 s` *walltime* sin traza) e `iverilog`:
  - Fase 1 (recuperable): 7 inyecciones TMR (`PC=3`, `CTRL=4`) + 3 SBE en `cpuregs` (`SBU=3`) + prueba de bloqueo de falso positivo en `rs2` especulativo (`x18`) + 2 SBE en IMEM (`ISBU=2`) + 2 SBE en DMEM (`DSBU=2`), verificando *auto-scrubbing* y lectura exacta por UART en `[SHRV32 Latido] Contador = 1` (`PC=00000003 CTRL=00000004 SBU=00000003 DBU=00000000 ISBU=00000002 IDBU=00000000 DSBU=00000002 DDBU=00000000`).
  - Fase 2 (errores dobles fatales, tras `LEDs = 0x0020`): inyección secuencial con *reset* entre pruebas de DBE en `cpuregs[x8]`, DBE en IMEM y DBE en DMEM, confirmando `trap = 1` inmediato (`count_ecc_reg_dbu=1`, `imem_dbu=1`, `dmem_dbu=1`) en los 3 casos.

### Métricas de implementación Post-Route (`xc7a100tcsg324-1` @ 100 MHz)

Comparativa de las tres implementaciones cerradas en el Hito 2 frente al Hito 1 (TMR sin ECC):
1. **Vivado RTL (100 % Verilog portable):** Hsiao RTL en `cpuregs`, `imem` y `dmem`.
2. **Vivado + IP Soft ECC (`VIVADO_ECC_IP=1`):** Hsiao RTL en `cpuregs` e `imem`, e IP `blk_mem_gen_dmem_ecc` en `dmem`.
3. **`openXC7` (`SYNTH=openxc7`):** flujo libre completo (`Yosys 0.69` + `nextpnr-xilinx`) sobre el RTL 100 % portable, validado también en placa física.

| Recurso / Métrica | Hito 1 (TMR) | Hito 2 Vivado (RTL puro) | Hito 2 Vivado (IP Soft ECC) | Hito 2 `openXC7` (RTL puro) |
| --- | ---: | ---: | ---: | ---: |
| **Slice LUTs (Vivado) / `SLICE_LUTX` (`nextpnr`)** | `1429` (`2.25 %`) | `2135` (`3.37 %` · `+706`) | `2111` (`3.33 %` · `+682`) | `3886 / 126800` (`3 %` · `2580` LUTs Yosys) |
| **LUT as Logic / LUT as Distributed RAM** | `1385` / `44` | `2079` / `56` | `2055` / `56` | `2580` / `14 RAM32M` |
| **Slice Registers (FF)** | `936` (`0.74 %`) | `1375` (`1.08 %` · `+439`) | `1368` (`1.08 %` · `+432`) | `1360` (`1 %` · `1349 FDRE` + `11 FDSE`, `+439` vs. Harvard) |
| **Block RAM Tiles (`RAMB36` eq.)** | `4` (`4 RAMB36E1`) | `5` (`4 RAMB36E1` + `2 RAMB18E1`) | `5` (`4 RAMB36E1` + `2 RAMB18E1`) | `5` eq. (`10 RAMB18E1` / `270`, `3 %`) |
| **Carry Chains (`CARRY4`)** | — (`126` `openXC7`) | `159` | `159` | `179` (`176` Yosys) |
| **WNS Setup @ 100 MHz** | `+2.298 ns` | `+0.226 ns` (`0` fallos) | `+0.240 ns` (`0` fallos) | `+0.40 ns` (`PASS`) |
| **WHS Hold @ 100 MHz** | `+0.110 ns` | `+0.033 ns` (`0` fallos) | `+0.061 ns` (`0` fallos) | `PASS` |
| **$F_{\max}$ estimada (`clk`)** | $\approx 129.8\text{ MHz}$ | $\approx 102.3\text{ MHz}$ | $\approx 102.5\text{ MHz}$ | `104.13 MHz` |

### Observaciones técnicas
- **Coste de área del endurecimiento ECC:** proteger `cpuregs`, `imem` y `dmem` añade `~682–706` Slice LUTs, `+432–439` FFs y solo **`+1` Block RAM Tile** (`5` tiles en total frente a `4`, pasando cada banco de `2048 × 32` a `2048 × 39` bits con `2 RAMB36E1 + 1 RAMB18E1`), más `+2` primitivas `RAM32M` (`14` en total) para almacenar los 7 bits extra de paridad en el banco de registros sin perder inferencia de LUTRAM.
- **Resolución del DRC `MDRV-1` en `blk_mem_gen_dmem_ecc`:** activar simultáneamente `CONFIG.ECC {true}` y `CONFIG.softecc {true}` en Tcl encendía a la vez `C_USE_ECC = 1` (ECC *hard* de primitiva `RAMB36E1` en modo `512 × 64`, forzando 4 bancos en profundidad y el mux `has_mux_b.B`) y `C_USE_SOFTECC = 1` (ECC *soft* en LUTs), generando doble driver sobre `sbiterr` y `dbiterr`. Fijar `CONFIG.ECC {false}` junto a `CONFIG.ecctype {Soft_ECC}` y `CONFIG.softecc {true}` selecciona exclusivamente el modo *Soft ECC* (`C_USE_ECC = 0, C_USE_SOFTECC = 1`), reduciendo DMEM a `2 RAMB36E1 + 1 RAMB18E1` y eliminando por completo el conflicto DRC.
- **Camino crítico a 100 MHz (`WNS = +0.240 ns`):** la ruta crítica ya no pasa por las memorias BRAM (aisladas por el registro `rdata_o` de `bram_ecc`), sino por la lectura asíncrona en LUTRAM de `cpuregs` + decodificación combinacional Hsiao (`u_dec_rs1`/`u_dec_rs2`) + lógica de detección/votación TMR (`9.611 ns` en Vivado con IP; `9.772 ns` en Vivado RTL; `9.60 ns` en `openXC7`). Los tres flujos cierran *timing* a `100.000 MHz` sin violaciones.

---

## [2026-11-19] — Consolidación arquitectónica y migración a HPicoRV32

### Objetivo
Auditar, limpiar y consolidar todas las modificaciones de endurecimiento (TMR selectivo con *self-healing*, bus Harvard `W^X`, ECC Hsiao SEC-DED en `cpuregs`/`IMEM`/`DMEM` y CSRs de telemetría), completar la cobertura de verificación en simulación (incluyendo violaciones Harvard `W^X`), migrar el nombre del proyecto de `SHRV32` a **HPicoRV32** (*Hardened PicoRV32*) y validar una síntesis limpia en `openXC7`.

### Cambios consolidados
- **Higiene RTL (`rtl/core/`, `rtl/mem/`):**
  - Cabeceras estándar `HPicoRV32` (preservando la licencia ISC original en [`picorv32.v`](../rtl/core/picorv32.v)), `` `timescale 1 ns / 1 ps `` en [`tmr_voter.v`](../rtl/core/tmr_voter.v), [`bram_sp.v`](../rtl/mem/bram_sp.v) y [`bram_ecc.v`](../rtl/mem/bram_ecc.v), limpieza de comentarios obsoletos y supresión puntual de `UNUSEDSIGNAL` sobre `reencoded[31:0]` en [`ecc_secded.v`](../rtl/core/ecc_secded.v).
  - En [`bram_sp.v`](../rtl/mem/bram_sp.v), parámetros por defecto alineados a `WORDS = 2048` / `ADDR_BITS = 11` y declaración `integer init_idx;` movida dentro de `gen_zero_init` para eliminar avisos estáticos cuando `USE_INIT = 1`.
- **Parametrización del SoC ([`soc.v`](../rtl/top/soc.v)):**
  - Exposición de `ENABLE_TMR` y `ENABLE_REG_ECC` en el módulo raíz y derivación automática de `IMEM_ADDR_BITS`/`DMEM_ADDR_BITS` mediante función constante `clog2` Verilog-2001 y cálculo `dmem_byte_off = mem_addr - DMEM_BASE`.
- **Cobertura de pruebas ([`tb_soc.v`](../tb/tb_soc.v)):**
  - Adición de `check_harvard_exec_dmem` (*fetch* ilegal en `0x0000_2000`) y `check_harvard_write_imem` (escritura ilegal en `0x0000_0000`), verificando `harv_err`, bloqueo de `imem_sel`/`dmem_sel`, enclavamiento de `harv_fault_r` $\rightarrow$ `trap = 1` y respuesta `mem_ready = 1`.
- **Infraestructura, firmware y documentación:**
  - Actualización a `HPicoRV32` (`hpicorv32.bit` / `hpicorv32.xpr`) en [`Makefile`](../Makefile), `fpga/nexys_a7/`, [`sw/`](../sw/), [`.vscode/settings.json`](../.vscode/settings.json), [`AGENTS.md`](../AGENTS.md), [`README.md`](../README.md) y fuentes `.tex`/`.tikz` en [`docs/arch/`](arch/).
  - Detección dinámica `VLT_PROCASSINIT_FLAG` en [`Makefile`](../Makefile) para compatibilidad multi-versión con Verilator, desacoplamiento `SIM_DEPS` para pruebas unitarias sin toolchain RISC-V, y conservación de [`bootloader.c`](../sw/boot/bootloader.c) y [`upload.py`](../sw/common/upload.py) como referencia histórica pre-Harvard.

### Verificación en simulación y linting
- **Lint estricto (`Verilator 5.054`):**
  - Módulos propios con `-Wall`: `0` avisos y `0` errores en `tmr_voter.v`, `ecc_secded.v` (`-Wno-DECLFILENAME`), `bram_sp.v` y `bram_ecc.v`.
  - Matriz de parámetros en `soc`: `0` errores en `ENABLE_TMR=0/1 × ENABLE_REG_ECC=0/1`, con `IMEM_WORDS=4096, DMEM_WORDS=1024`, y en backend dual `-DVIVADO_ECC_IP=1` (con *stub* de `blk_mem_gen_dmem_ecc`).
- **Batería de testbenches (`iverilog -g2001` y `Verilator`):**
  - [`tb_tmr_voter.v`](../tb/tb_tmr_voter.v): `5/5` casos superados en ambos simuladores.
  - [`tb_ecc_secded.v`](../tb/tb_ecc_secded.v): `5468/5468` comprobaciones superadas en ambos simuladores.
  - [`tb_bram_ecc.v`](../tb/tb_bram_ecc.v): `6/6` pruebas superadas en ambos simuladores.
  - [`tb_soc.v`](../tb/tb_soc.v) (`SIM_FAST=1`): superado sin errores en `Verilator` (`2.365 s` sin traza) y en `iverilog` (4 estados), validando banner `HPicoRV32 (Hardened PicoRV32) - Nexys A7-100T`, latido `[HPicoRV32 Latido] Contador = 1 | PC=00000003 CTRL=00000004 SBU=00000003 DBU=00000000 ISBU=00000002 IDBU=00000000 DSBU=00000002 DDBU=00000000`, 3 fallos DBE fatales y 2 violaciones Harvard `W^X`.

### Métricas de implementación en `openXC7` (`xc7a100tcsg324-1` @ 100 MHz)
Firmware de FPGA compilado con `SIM_FAST=0` (`.text = 908` B, `.data = 4` B, `.bss = 4` B) y generación limpia de `build/openxc7/hpicorv32.bit` (`3825904` bytes):

| Recurso / Métrica | Hito 2 `openXC7` (SHRV32) | Consolidación `openXC7` (HPicoRV32) | Delta |
| --- | ---: | ---: | ---: |
| **Yosys Logic LUTs (`LUT2`–`LUT6`)** | `2580` | `2617` (`513 LUT2`, `520 LUT3`, `424 LUT4`, `856 LUT5`, `304 LUT6`) | `+37` |
| **Post-route `SLICE_LUTX` (`nextpnr`)** | `3886 / 126800` (`3 %`) | `3922 / 126800` (`3 %`) | `+36` |
| **LUTRAM (`RAM32M` / `cpuregs`)** | `14` | `14` | `0` |
| **Flip-Flops (`SLICE_FFX`)** | `1360` (`1349 FDRE` + `11 FDSE`) | `1360 / 126800` (`1 %` · `1349 FDRE` + `11 FDSE`, `0` latches) | `0` |
| **Block RAM (`RAMB18E1`)** | `10 / 270` (`5` eq. `RAMB36`) | `10 / 270` (`3 %` · `5` eq. `RAMB36`) | `0` |
| **Carry Chains (`CARRY4`)** | `179` (`176` Yosys) | `178 / 15850` (`1 %` · `176` Yosys) | `-1` (`0` Yosys) |
| **$F_{\max}$ (`cpu.clk` @ 100 MHz)** | `104.13 MHz` (`PASS`) | `112.82 MHz` (`PASS`, `3 warnings, 0 errors`) | `+8.69 MHz` |

### Observaciones de auditoría post-síntesis (`soc.json` y `nextpnr.log`)
- **Cero *latches* y preservación exacta 3× de TMR:** la inspección de `build/openxc7/soc.json` confirma `0` celdas `LDCE`/latch y las 3 réplicas exactas en los 5 registros protegidos (`reg_pc`: `32/32/32`, `reg_next_pc`: `32/32/32`, `cpu_state`: `8/8/8`, `latched_rd`: `5/5/5`, `mem_state`: `2/2/2`).
- **Camino crítico:** `imem.u_bram.mem.0.2.DOADO6` $\rightarrow$ decodificador Hsiao (`imem.dec_sbiterr`) $\rightarrow$ `$auto$ff.cc:337:slice$17695.D` (`8.86 ns` totales: `3.60 ns` lógica + `5.26 ns` ruta, *slack* mínimo positivo `+1.14 ns` frente al periodo de `10.00 ns`).
- **Coste de parametrización (`clog2` / `dmem_byte_off`):** `0` FFs, `0` `RAMB18E1`, `0` `RAM32M` y `0` `CARRY4` adicionales en Yosys.

---

## [2026-11-22] — Fase 1 (Tarea 1): Especificación del sistema de inyección de fallos desacoplado (`docs/fi-spec`)

### Objetivo
Definir la arquitectura, interfaz y metodología de verificación de un mecanismo de inyección de fallos desacoplado del SoC (válido tanto en simulación RTL como en hardware sobre la **Nexys A7-100T**), cerrando las decisiones de diseño de la Fase 1 y alineando el criterio de evaluación experimental con el artículo de referencia de **HARV** ([`harv_notes.md`](harv_notes.md#L190)).

### Decisiones de arquitectura (Opción B — Inyector HW desacoplado)

1. **Desacoplamiento del bus y aislamiento de vuelo (`soc` vs. `soc_core`):**
   - El módulo inyector (`rtl/periph/fault_injector.v`) **no se conecta al bus de memoria/MMIO de `picorv32`** ni requiere colaboración del firmware bajo prueba, evitando el *efecto observador* y manteniendo el control del experimento aunque la CPU entre en `trap` o *hang*.
   - Se extraerá el cuerpo actual de [`soc.v`](../rtl/top/soc.v) a `rtl/top/soc_core.v` con `parameter [0:0] ENABLE_FI = 1'b0` y el bus FI como puertos dedicados.
   - [`soc.v`](../rtl/top/soc.v) permanecerá como *wrapper* de vuelo instanciando `soc_core #(.ENABLE_FI(1'b0))`, conservando intactos los 6 puertos físicos de [`Nexys-A7-100T-Master.xdc`](../fpga/nexys_a7/Nexys-A7-100T-Master.xdc) (`clk`, `resetn`, `trap`, `leds`, `ser_tx`, `ser_rx`) y garantizando **0 % de sobrecoste** en área, FFs, LUTRAM, BRAM y timing mediante `generate if (ENABLE_FI)`.
   - Para pruebas en placa (`FI=1`), `rtl/top/soc_fi_top.v` instanciará `soc_core #(.ENABLE_FI(1'b1))` junto con `fault_injector`, mapeado a `SW[4:0]` y `BTNC` en `fpga/nexys_a7/Nexys-A7-100T-FI.xdc`.

2. **Protocolo de *handshake* armado hasta consumo (`fi_valid` / `fi_ack`):**
   - **Por qué hace falta:** los registros TMR se actualizan cada ciclo (`ack` inmediato), pero `cpuregs` solo se escribe cuando `cpuregs_cpu_wen = 1` y `imem`/`dmem` solo decodifican en `ST_READ`/`ST_RMW_READ`. Un pulso ciego de 1 ciclo se perdería casi siempre en DMEM o `cpuregs`.
   - **Interfaz del bus FI hacia `soc_core`:**
     - Entradas: `fi_valid_i`, `fi_target_i[3:0]`, `fi_rep_mask_i[2:0]`, `fi_bit_mask_i[38:0]`.
     - Salida: `fi_ack_o` (pulso combinacional de 1 ciclo emitido por el objetivo cuando consume la inyección).
   - **Temporización sin lazos combinacionales:** todas las salidas de `fault_injector.v` (`fi_valid_o`, `fi_target_o`, `fi_rep_mask_o`, `fi_bit_mask_o`) salen registradas en flip-flops (`ST_ARMED`). El objetivo activo devuelve `fi_ack_o = 1` de forma puramente combinacional a partir de `fi_valid_i` y su estado registrado; en el mismo `posedge clk`, el objetivo captura el *bit-flip* y `fault_injector` desarma `fi_valid_o <= 1'b0`.
   - **Regla de seguridad (*gating*):** dentro de `soc_core` y `picorv32`, toda inyección se habilita únicamente bajo `sys_resetn && !trap && (cpu_state != cpu_state_trap)`, impidiendo corromper el POR de 63 ciclos o sacar a la CPU de un estado `trap`.

3. **Mapa de objetivos (`fi_target[3:0]`) y ubicación exacta de cada saboteador XOR:**

| `fi_target` | Módulo | Elemento objetivo | Ancho útil | Punto de inyección XOR | Modelo y comportamiento |
| :---: | --- | --- | :---: | --- | --- |
| `4'd0` | `picorv32` | `reg_pc_r0..r2` | `32` b | Entrada `D` (`next_reg_pc ^ mask`) | SEU/MBU en FF; ejercita votación + *self-healing* |
| `4'd1` | `picorv32` | `reg_next_pc_r0..r2` | `32` b | Entrada `D` (`next_reg_next_pc ^ mask`) | SEU/MBU en FF; ejercita votación + *self-healing* |
| `4'd2` | `picorv32` | `cpu_state_r0..r2` | `8` b | Entrada `D` (`next_cpu_state ^ mask`) | SEU/MBU en FSM principal (`!trap` y `!= trap`) |
| `4'd3` | `picorv32` | `mem_state_r0..r2` | `2` b | Entrada `D` (`next_mem_state ^ mask`) | SEU/MBU en FSM de memoria |
| `4'd4` | `picorv32` | `latched_rd_r0..r2` | `5` b | Entrada `D` (`next_latched_rd ^ mask`) | SEU/MBU en índice `rd` (`regindex_bits`) |
| `4'd5` | `picorv32` | `cpuregs` (`32 × 39` b) | `39` b (`32` sin ECC) | `cpuregs_wrdata_enc ^ mask` en `cpuregs_cpu_wen` | Preserva 1 puerto `W` (`14 RAM32M`) y **0 ns** en lectura |
| `4'd6` | `bram_ecc` | `imem` (`2048 × 39` b) | `39` b | `bram_rdata ^ mask` en `ST_READ` | SBE/DBE antes de `u_dec`; dispara `ST_SCRUB` / `trap` |
| `4'd7` | `bram_ecc` | `dmem` (`2048 × 39` b) | `39` b | `bram_rdata ^ mask` en `ST_READ \|\| ST_RMW_READ` | SBE/DBE antes de `u_dec`; dispara `ST_SCRUB`, aborto RMW / `trap` |

   - **Comparativa justa con `ENABLE_TMR = 0` / `ENABLE_REG_ECC = 0` (estilo HARV):**
     - En objetivos TMR (`0..4`), si `ENABLE_TMR = 0` solo existe la copia física `_r0`, por lo que cualquier petición con `|fi_rep_mask_i` inyectará directamente sobre `_r0` (evitando falsos enmascaramientos al medir el diseño base sin proteger).
     - En `cpuregs` (`4'd5`), cuando `ENABLE_ECC = 0` el banco mide `32` bits, acotando la posición aleatoria de bit al rango `[31:0]`.
   - **Preservación de *timing* y LUTRAM:** al inyectar en `cpuregs_wrdata_enc` (camino de escritura) en lugar de `cpuregs_raw1/2` (camino de lectura asíncrona), se conserva la inferencia de `14 RAM32M` y no se degrada el camino crítico actual de lectura (`cpuregs -> u_dec_rs1 -> TMR`). En `imem`, las salidas registradas de `fault_injector` limitan el impacto en `bram_rdata` a 1 nivel XOR (solo cuando `ENABLE_FI = 1`).
   - **Política `VIVADO_ECC_IP`:** la configuración de vuelo (`FI = 0`) mantiene `VIVADO_ECC_IP=1` en Vivado; la configuración de laboratorio en placa (`FI = 1`) sintetiza `dmem` con el backend RTL Hsiao portable (sin `blk_mem_gen_dmem_ecc`) para inyectar libremente cualquier patrón SBE/DBE sobre los 39 bits físicos.

4. **Especificación funcional de `rtl/periph/fault_injector.v`:**
   - **PRNG LFSR de 32 bits:** polinomio primitivo de longitud máxima ($x^{32} + x^{22} + x^2 + x + 1$) con semilla configurable garantizada distinta de cero tras reset.
   - **Muestreo uniforme por rechazo (*rejection sampling*):** en `ST_IDLE`, descarta valores fuera de rango antes de armar `ST_ARMED` (`raw_bit >= 5` en `latched_rd`, `raw_bit >= 39` en ECC/BRAM, `raw_rep == 2'b11` en réplicas TMR y `raw_target >= 6` en perfil CPU-only), logrando distribución uniforme exacta sin sesgo ni divisores combinacionales.
   - **Modos de disparo:**
     - **Dirigido:** carga `(target, rep_mask, bit_mask)` externos al recibir pulso `trig_i`.
     - **Autónomo (LFSR):** temporizador por `interval_cycles` y presupuesto `max_faults` (p. ej. `1` o `10` SEUs espaciados en el tiempo, o flujo continuo con `max_faults = 0` para demo en placa), más selección de perfil **CPU-only** (`0..5`, comparable a HARV) frente a **SoC completo** (`0..7`).
   - **Soporte de fallos fatales dirigidos:** además de `1-SEU`/`10-SEU`, genera máscaras *two-hot* (2 bits distintos para DBE en `cpuregs`/IMEM/DMEM) y soporta salto forzado en `reg_pc` con `fi_rep_mask = 3'b111` hacia `0x0000_2000` para ejercitar la barrera Harvard `W^X` en hardware real.
   - **Telemetría propia:** contador `inj_count_o` incrementado únicamente en `fi_valid_o && fi_ack_i`, más bandera `fi_timeout_o` si un objetivo pasivo no responde dentro del límite configurado.

5. **Especificación de campaña automatizada en simulación (Hito 5, estilo HARV):**
   - **Benchmark finito determinista (`sw/apps/fi_bench/main.c`):** implementación en C bare-metal del algoritmo **Sum of vectors** de HARV (dos arrays de `300` elementos `uint32_t` sumados en un tercer array en DMEM; `3 × 300 × 4 = 3600` B < `8192` B de DMEM) con salida UART separada en oráculo funcional (`RESULT=0xXXXXXXXX`) y telemetría (`TELEM PC=... CTRL=... SBU=... DBU=... ISBU=... IDBU=... DSBU=... DDBU=...`), finalizando con `REG_LEDS = 15'h7FFF`.
   - **Banco de campaña (`tb/tb_fault_campaign.v`):**
     - **Etapa 0 (*Golden run*):** mide `golden_cycles` y captura `golden_result` por UART sin inyecciones.
     - **Etapa 1 (Campaña recuperable `1-SEU` y `10-SEU` espaciados):** `100` tiradas por defecto (`+NUM_RUNS=1000` en Verilator `TRACE=0`), comparando `ENABLE_TMR/REG_ECC` en `0` vs. `1` y perfil CPU-only vs. SoC completo.
     - **Etapa 2 (Campaña fatal dirigida):** DBE en `cpuregs`, IMEM y DMEM + violación Harvard `W^X`, verificando `trap == 1` y telemetría `DBU`/`harv_fault_r` con reset entre tiradas.
     - **Clasificación automática (Tabla 9 de HARV):** `Match` (subdividido en *Corrected/Masked* y *Latent*), `Mismatch` (SDC), `Hang` (> `2 × golden_cycles` o `trap` inesperado) y `Trap controlado` (solo Etapa 2).

### Hoja de ruta de ejecución (Fase 1)
1. **Hito 1 (`docs/fi-spec`):** Especificación técnica (*cerrado en esta entrada*).
2. **Hito 2 (`feat/fault-injector`):** `rtl/periph/fault_injector.v` + `tb/tb_fault_injector.v`.
3. **Hito 3 (`feat/soc-fi-hooks`):** Separación `soc`/`soc_core` + hooks `ENABLE_FI` en `picorv32.v` y `bram_ecc.v` + auditoría `0 % overhead` en `openXC7`.
4. **Hito 4 (`feat/nexys-fi-demo`):** `rtl/top/soc_fi_top.v` + `Nexys-A7-100T-FI.xdc` + `FI=1` en `Makefile` + prueba en Nexys A7-100T.
5. **Hito 5 (`tb/fault-campaign`):** `sw/apps/fi_bench/` + `tb/tb_fault_campaign.v` + métricas de campaña en `docs/logbook.md`.

---

### Hitos 4 y 5 (Fase 1 Completa): Demo Nexys A7 (`FI=0/1`), Campaña HARV (1,000 corridas) y Ablación TMR×ECC

- **Ramas integradas:** `feat/nexys-fi-demo` -> `main`, y cierre en `tb/fault-campaign` -> `main`.
- **Revisión arquitectónica de `VIVADO_ECC_IP_FI` (Hito 4):**
  - Se actualiza y sustituye la nota preliminar de Hito 1 que planteaba omitir `blk_mem_gen_dmem_ecc` cuando `FI=1`. Para mantener exactamente el mismo flujo de memoria IP de Xilinx en Vivado, [create_project.tcl](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/fpga/nexys_a7/create_project.tcl) recibe `-tclargs $(FI)` desde el [Makefile](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/Makefile):
    - `FI=0` (vuelo): top `soc`, [Nexys-A7-100T-Master.xdc](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/fpga/nexys_a7/Nexys-A7-100T-Master.xdc) y defines `{VIVADO_MEM_INIT=1 VIVADO_ECC_IP=1}`.
    - `FI=1` (laboratorio): top `soc_fi_top`, [Nexys-A7-100T-FI.xdc](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/fpga/nexys_a7/Nexys-A7-100T-FI.xdc) y defines `{VIVADO_MEM_INIT=1 VIVADO_ECC_IP=1 VIVADO_ECC_IP_FI=1}`, activando en la IP `CONFIG.Use_Error_Injection_Pins {true}` y `CONFIG.Error_Injection_Type {Single_and_Double_Bit_Error_Injection}`.
  - En [bram_ecc.v](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/rtl/mem/bram_ecc.v), la inyección bajo `VIVADO_ECC_IP_FI` ataca los pines `.injectsbiterr` y `.injectdbiterr` durante escrituras (`ip_wea && state != ST_SCRUB`), mientras que el backend RTL y simulación inyectan XOR combinacional en lectura (`ST_READ` / `ST_RMW_READ`).
  - *Nota de verificación:* En este entorno macOS no hay instalación local de `vivado`, por lo que la integración de `VIVADO_ECC_IP=1` / `VIVADO_ECC_IP_FI=1` se verificó con `verilator --lint-only -Wall` contra un stub de `blk_mem_gen_dmem_ecc` (`0` errores), quedando la corrida batch completa de Vivado para la estación con Vivado.

- **Implementación de demo en placa (Hito 4):**
  - [soc_fi_top.v](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/rtl/top/soc_fi_top.v): sincronizadores 2-FF para entradas asíncronas `sw[4:0]` y `btnc`, debouncer de `10 ms` (`DEBOUNCE_CYCLES=1000000`), modo autónomo LFSR continuo a `10 fallos/s` (`AUTO_INTERVAL=32'd10000000`), `ACK_TIMEOUT=32'd2000000` (`20 ms`) para cubrir impresiones UART largas de `counter`, y disparo `W^X` al combinar `sw[3]=1` + `sw[2:0]=3'd1` (`reg_next_pc ^= 32'h0000_2000` en 3 réplicas).
  - En [fault_injector.v](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/rtl/periph/fault_injector.v) se añadió `armed_auto_q` para abortar limpiamente `ST_ARMED -> ST_IDLE` si se baja `sw[4]` en placa antes de recibir ACK.
  - **Cierre de temporización en `openXC7`:** al eliminar el acoplamiento de `state` del multiplexor de lectura ECC en `bram_ecc.v`, aligerar la carga de `cpuregs_cpu_wen` en `picorv32.v` y activar `--tmg-ripup` en `nextpnr-xilinx`:
    - `FI=0` (`soc`): `106.97 MHz` (`PASS @ 100 MHz`, holgura `+652 ps`), bitstream generado.
    - `FI=1` (`soc_fi_top`): `103.49 MHz` (`PASS @ 100 MHz`, holgura `+337 ps`), `1527` FFs (`1500 FDRE + 27 FDSE`), `14 RAM32M`, `10 RAMB18E1`, `198 CARRY4`, `0` latches y réplicas TMR preservadas (`96/96`, `96/96`, `24/24`, `6/6`, `15/15` redes distintas), bitstream generado.

- **Benchmark y campaña HARV automatizada (Hito 5):**
  - [fi_bench/main.c](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/sw/apps/fi_bench/main.c): *Sum of vectors* bare-metal de `300` elementos `uint32_t` (`vec_a`, `vec_b`, `vec_c` en DMEM + `.rodata` en IMEM + mezcla RMW `sb`/`sh`), rutina de entrada `__attribute__((naked))` que limpia `x1, x5..x31` para aislar corridas sucesivas sin fuga de SEUs latentes (`1288 B` `.text`, `16 B` `.data`, `3600 B` `.bss`). Emite `RESULT=0x01d3a7bf` y `TELEM ...` por UART antes de señalizar fin en `REG_LEDS=0x7FFF` (`118,720` ciclos totales, `78,758` de cómputo con `SIM_FAST=1`).
  - [picorv32.v](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/rtl/core/picorv32.v): los CSRs de telemetría `0xCC0..0xCC3` devuelven `32'd0` cuando `ENABLE_TMR=0` o `ENABLE_ECC=0` (`0%` impacto con ambos habilitados), habilitando la matriz de ablación `ENABLE_TMR × ENABLE_REG_ECC` con el mismo firmware.
  - [tb_fault_campaign.v](file:///Users/julianhinojosagil/Documents/Dev/HPicoRV32/tb/tb_fault_campaign.v): muestreo síncrono en `@(negedge clk)`, receptor UART automático, Etapa 0 (`GOLDEN` y `GOLDEN-BASE`), Etapa 1 (`1-SEU` y `10-SEU` espaciados al `5%` del cómputo en perfiles CPU `0..5` y SoC `0..7`, más comparativa A/B pareada con `u_base`) y Etapa 2 (DBE dirigido en `cpuregs`, `IMEM`, `DMEM` y salto `W^X`).

- **Resultados observados en campaña Verilator (`TRACE=0`, `fi_bench SIM_FAST=1`):**

| Configuración (`TMR, REG_ECC`) | Perfil / Escenario | Corridas (`N`) | SEUs inyectados (`no-ack=0`) | `Match` (Correg. / Lat.) | `SDC` (`Mismatch`) | `Hang` |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **`(1,1)` Completo (`SOC_PROT`)** | `1-SEU CPU (0..5)` | `1000` | `1000` | **`1000` (`100.0%`)** (`1000` / `0`) | `0` | `0` |
| **`(1,1)` Completo (`SOC_PROT`)** | `1-SEU ALL (0..7)` | `1000` | `1000` | **`1000` (`100.0%`)** (`1000` / `0`) | `0` | `0` |
| **`(1,1)` Completo (`SOC_PROT`)** | `10-SEU CPU (0..5)` | `1000` | `10000` | **`1000` (`100.0%`)** (`1000` / `0`) | `0` | `0` |
| **`(1,1)` Completo (`SOC_PROT`)** | `10-SEU ALL (0..7)` | `1000` | `10000` | **`1000` (`100.0%`)** (`1000` / `0`) | `0` | `0` |
| `(1,0)` Solo TMR (`REG_ECC=0`) | `1-SEU CPU (0..5)` | `200` | `200` | `158` (`79.0%`) (`158` / `0`) | `33` (`16.5%`) | `9` (`4.5%`) |
| `(1,0)` Solo TMR (`REG_ECC=0`) | `1-SEU ALL (0..7)` | `200` | `200` | `173` (`86.5%`) (`173` / `0`) | `25` (`12.5%`) | `2` (`1.0%`) |
| `(1,0)` Solo TMR (`REG_ECC=0`) | `10-SEU CPU (0..5)` | `200` | `1897` | `44` (`22.0%`) (`44` / `0`) | `91` (`45.5%`) | `65` (`32.5%`) |
| `(1,0)` Solo TMR (`REG_ECC=0`) | `10-SEU ALL (0..7)` | `200` | `1888` | `57` (`28.5%`) (`57` / `0`) | `112` (`56.0%`) | `31` (`15.5%`) |
| `(0,1)` Solo Reg-ECC (`TMR=0`) | `1-SEU CPU (0..5)` | `200` | `200` | `82` (`41.0%`) (`24` / `58`) | `15` (`7.5%`) | `103` (`51.5%`) |
| `(0,1)` Solo Reg-ECC (`TMR=0`) | `1-SEU ALL (0..7)` | `200` | `200` | `117` (`58.5%`) (`72` / `45`) | `17` (`8.5%`) | `66` (`33.0%`) |
| `(0,1)` Solo Reg-ECC (`TMR=0`) | `10-SEU CPU (0..5)` | `200` | `1067` | `1` (`0.5%`) (`1` / `0`) | `3` (`1.5%`) | `196` (`98.0%`) |
| `(0,1)` Solo Reg-ECC (`TMR=0`) | `10-SEU ALL (0..7)` | `200` | `815` | `1` (`0.5%`) (`1` / `0`) | `2` (`1.0%`) | `197` (`98.5%`) |
| `(0,0)` Baseline sin TMR/Reg-ECC | `1-SEU CPU (0..5)` | `1000` | `1000` | `297` (`29.7%`) (`0` / `297`) | `215` (`21.5%`) | `488` (`48.8%`) |
| `(0,0)` Baseline sin TMR/Reg-ECC | `10-SEU CPU (0..5)` | `1000` | `5256` | `0` (`0.0%`) (`0` / `0`) | `5` (`0.5%`) | `995` (`99.5%`) |

- **Etapa 2 (fallos fatales dirigidos sobre `(1,1)`):** `cpuregs` DBE (`cpu_trap=1, reg_dbu=1`), `IMEM` DBE (`ecc_fault_r=1, imem_dbu=1`), `DMEM` DBE (`ecc_fault_r=1, dmem_dbu=1`) y salto `W^X` en `reg_next_pc -> 0x2000` (`harv_fault_r=1`), todos con `trap=1` controlado. En Icarus Verilog (`+NUM_RUNS=10`), también pasó todas las etapas (`0 SDC`, `0 Hang` en `SOC_PROT`, `build/dump.vcd` de `330 MB`).
