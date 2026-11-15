# Bitácora Técnica — SHRV32

Registro cronológico de hitos, verificaciones en simulación y métricas reales de implementación (*post-route* `impl_1`) en **Digilent Nexys A7-100T** (`xc7a100tcsg324-1`) para comparar la evolución de recursos y frecuencia frente al diseño base.

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
