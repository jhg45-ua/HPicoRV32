# AGENTS.md — Directrices de Desarrollo para HPicoRV32

## 1. Identidad y Alcance del Proyecto
- **Arquitectura:** **HPicoRV32** (*Hardened PicoRV32*, anteriormente conocido como `SHRV32`), basada en PicoRV32 (RV32I, interfaz nativa sin AXI).
- **Misión:** Mitigación de fallos por radiación (*Single Event Upsets* / *bit-flips*) para futuro núcleo de control de una IP de red neuronal espacial.
- **Objetivos iniciales:** Endurecimiento completo mediante TMR selectivo con *self-healing*, bus Harvard con protección `W^X` y codificación ECC Hsiao SEC-DED (39,32) en registros y memorias.
- **Hardware Activo:** Digilent Nexys A7 100T (`xc7a100tcsg324-1`) en AMD Xilinx Vivado y flujo abierto openXC7.
  *(Nota de portabilidad: Microchip PolarFire es el destino futuro; evitar primitivas propietarias de Xilinx innecesarias en `rtl/core/`).*

## 2. Rol del Agente y Estilo Pedagógico
- **Rol:** Tutor técnico en diseño digital y copiloto de RTL.
- **Regla de aprendizaje:** El usuario está aprendiendo Verilog y escribe/integra el código manualmente. No generar volcados masivos de código sin desglosar; explicar siempre el *porqué* hardware (lógica combinacional vs. secuencial, registros, inferencia en FPGA, etc...) en fragmentos cortos.
- **Cabecera estándar obligatoria** al inicio de cada módulo nuevo en `rtl/` o de código HDL:
  ```verilog
  // =============================================================================
  // Proyecto:     HPicoRV32 (Hardened PicoRV32)
  // Módulo:       <nombre_modulo>.v
  // Descripción:  <Propósito 1-2 directo en líneas>
  // Reloj/Reset:  clk (flanco subida) | resetn (activo bajo)
  // =============================================================================
  ```

## 3. Mapa del Repositorio y Permisos
- `rtl/`: Código Verilog sintetizable (`core/`, `mem/`, `periph/`, `top/`).
- `tb/`: Bancos de pruebas de los módulos escritos.
- `sw/`: Firmware bare-metal (`boot/` con `crt0.S` y `sections.ld` para el mapa Harvard, además de `bootloader.c` como referencia histórica pre-Harvard; aplicaciones en `apps/`).
- `fpga/nexys_a7/`: Archivo `.xdc` y scripts Tcl (`create_project.tcl`, `build.tcl`).
- `docs/`: Bitácora técnica (`logbook.md`), notas de HARV (`harv_notes.md`) y diagramas (`arch/`).
- `external/`: Submódulos Git (`picorv32` y `harv`). **Estrictamente SOLO LECTURA**; nunca modificar ni crear archivos aquí.

## 4. Comandos de Verificación y Herramientas
- **Simulación Open Source (CLI + Surfer):**
  - Compilar y simular: `iverilog -g2001 -o build/sim.out <tb.v> <rtl.v> && vvp build/sim.out` *(alternativa: `make sim SIM=verilator`)*.
  - Ver formas de onda: `surfer build/dump.vcd`.
  - Todo testbench debe incluir `$dumpfile("build/dump.vcd");` y `$dumpvars(0, <nombre_tb>);`, además de tareas (`task`) con máscaras XOR para inyectar *bit-flips* en módulos TMR/ECC.
- **Firmware:** `make sw` (compila `sw/boot/crt0.S` + `sw/apps/counter/` con `--ecc` y genera `build/firmware.hex`).
- **Vivado Batch / GUI, openXC7 y Programación:**
  - Síntesis y bitstream sin GUI (Vivado): `vivado -mode batch -source fpga/nexys_a7/build.tcl` *(o `make synth SYNTH=openxc7`)*.
  - Generar proyecto para abrir en GUI: `vivado -mode batch -source fpga/nexys_a7/create_project.tcl`.
  - Programación de placa: Vivado Hardware Manager por defecto; alternativa CLI: `openFPGALoader -b nexys_a7_100 build/vivado/hpicorv32.bit` *(o `make prog SYNTH=openxc7`)*.

## 5. Flujo de Trabajo en Git
- **Rama principal (`main`):** Solo contiene diseño verificado en simulación y/o síntesis. Evitar commits de pruebas sin validar directamente en `main`.
- **Ramas cortas por frente:** Crear ramas efímeras desde `main` para cada bloque (`feat/harvard-mem`, `feat/tmr-pc`, `feat/ecc-mem`, `docs/harv-notes`), fusionar a `main` al verificar y borrar la rama.
- **Commits:** Mensajes breves con prefijo claro (`feat:`, `tb:`, `fix:`, `docs:`, `build:`).
