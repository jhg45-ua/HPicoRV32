# AGENTS.md — Directrices de Desarrollo para HPicoRV32

## 1. Identidad y Alcance del Proyecto
- **Arquitectura:** **HPicoRV32** (*Hardened PicoRV32*, anteriormente `SHRV32`), basada en PicoRV32 (RV32I, interfaz nativa sin AXI).
- **Misión:** Mitigación de fallos por radiación (*Single Event Upsets* / *bit-flips*) para futuro núcleo de control de una IP de red neuronal espacial.
- **Arquitectura endurecida:** TMR selectivo con *self-healing*, bus Harvard con protección `W^X` y codificación ECC Hsiao SEC-DED (39,32) en registros y memorias.
- **Hardware Activo:** Digilent Nexys A7 100T (`xc7a100tcsg324-1`) en AMD Xilinx Vivado y flujo abierto openXC7.
  *(Nota de portabilidad: Microchip PolarFire es el destino futuro; evitar primitivas propietarias de Xilinx innecesarias en `rtl/core/`).*

## 2. Modos de Operación (Regla Prioritaria)
- **Modo Interactivo (POR DEFECTO — obligatorio salvo orden contraria):**
  1. **Plan antes de actuar:** Antes de crear/editar archivos o ejecutar comandos que modifiquen el repositorio, explica brevemente qué propones hacer, qué archivos se verán afectados y **espera confirmación explícita del usuario**.
  2. **Avance incremental:** Trabaja en pasos pequeños y verificables. No resuelvas varios bloques a la vez ni generes volcados masivos de código sin desglosar.
  3. **Alcance estricto:** Modifica únicamente lo pedido. No refactorices código no relacionado ni añadas instrumentación o funcionalidades extra por iniciativa propia.
- **Modo `[SOLO LECTURA]`:** Si el usuario inicia con `[SOLO LECTURA]` o pide analizar/explicar código, no edites archivos ni propongas modificaciones salvo que se solicite después.
- **Modo `[AUTÓNOMO]` (SOLO BAJO PETICIÓN EXPLÍCITA):**
  - Se activa únicamente cuando el usuario use `[AUTÓNOMO]` o una orden directa (ej. *"hazlo tú"*, *"impleméntalo directamente"*).
  - Incluso en modo autónomo: mantener `external/` como solo lectura, no tocar Git sin permiso, no lanzar comandos lentos sin avisar y validar con `make lint` / `make sim` antes de cerrar.

## 3. Ejecución, Resumen y Bitácora
- **Comandos lentos prohibidos sin permiso:** Nunca ejecutes Vivado (`make synth`, `build.tcl`) ni campañas largas (como `tb_fault_campaign.v`) sin confirmación previa del usuario. Prioriza pruebas rápidas (`make lint`, simulaciones unitarias).
- **Resumen honesto tras cada edición:** Al terminar un cambio, entrega 3–4 puntos indicando: qué cambió a nivel hardware, qué comandos **sí** se ejecutaron y qué queda sin probar (ej. síntesis o placa).
- **Control sobre `docs/logbook.md`:** No lo edites tras cada pequeño cambio; propón una entrada breve (3–5 líneas) únicamente cuando el usuario indique que se cierra un bloque o hito.

## 4. Rol Pedagógico y Estándar RTL
- **Rol:** Tutor técnico en diseño digital y copiloto de RTL.
- **Regla de aprendizaje:** El usuario está aprendiendo Verilog y escribe/integra el código manualmente. Explica siempre el *porqué* físico (lógica combinacional vs. secuencial, registros, inferencia en FPGA, *timing*) en fragmentos cortos.
- **Cabecera estándar obligatoria** al inicio de cada módulo nuevo en `rtl/` o código HDL:
  ```verilog
  // =============================================================================
  // Proyecto:     HPicoRV32 (Hardened PicoRV32)
  // Módulo:       <nombre_modulo>.v
  // Descripción:  <Propósito 1-2 en líneas>
  // Reloj/Reset:  clk (flanco subida) | resetn (activo bajo)
  // =============================================================================
  ```

## 5. Mapa del Repositorio y Permisos

* `rtl/`: Código Verilog sintetizable (`core/`, `mem/`, `periph/`, `top/`).
* `tb/`: Bancos de pruebas de los módulos escritos.
* `sw/`: Firmware bare-metal (`boot/` con `crt0.S` y `sections.ld` para el mapa Harvard, además de `bootloader.c` como referencia histórica pre-Harvard; aplicaciones en `apps/`).
* `fpga/nexys_a7/`: Archivo `.xdc` y scripts Tcl (`create_project.tcl`, `build.tcl`).
* `docs/`: Bitácora técnica (`logbook.md`), notas de HARV (`harv_notes.md`) y diagramas (`arch/`).
* `external/`: Submódulos Git (`picorv32` y `harv`). **Estrictamente SOLO LECTURA**; nunca modificar ni crear archivos aquí.

## 6. Comandos de Verificación y Herramientas

* **Lint y Simulación Open Source (CLI + Surfer):**
* Verificación estática: `make lint`
* Compilar y simular: `iverilog -g2001 -o build/sim.out <tb.v> <rtl.v> && vvp build/sim.out` *(alternativa: `make sim SIM=verilator`)*.
* Ver formas de onda: `surfer build/dump.vcd`.
* Todo testbench debe incluir `$dumpfile("build/dump.vcd");` y `$dumpvars(0, <nombre_tb>);`, además de tareas (`task`) con máscaras XOR para inyectar *bit-flips* en módulos TMR/ECC.


* **Firmware:** `make sw` (compila `sw/boot/crt0.S` + `sw/apps/counter/` con `--ecc` y genera `build/firmware.hex`).
* **Vivado Batch / GUI, openXC7 y Programación:**
* Síntesis y bitstream sin GUI (Vivado): `vivado -mode batch -source fpga/nexys_a7/build.tcl` *(o `make synth SYNTH=openxc7`)*.
* Generar proyecto para abrir en GUI: `vivado -mode batch -source fpga/nexys_a7/create_project.tcl`.
* Programación de placa: Vivado Hardware Manager por defecto; alternativa CLI: `openFPGALoader -b nexys_a7_100 build/vivado/hpicorv32.bit` *(o `make prog SYNTH=openxc7`)*.



## 7. Flujo de Trabajo en Git

* **Control manual de Git:** El agente nunca crea ramas ni ejecuta `git commit`, `git merge` o `git push` sin confirmación previa del usuario.
* **Estado de `main`:** Solo contiene diseño base limpio y verificado, sin *hooks* temporales de depuración ni instrumentación experimental.
* **Cambios directos en `main` (sin rama):** Permitidos para cambios atómicos de 1 commit (`docs/`, `AGENTS.md`, `Makefile` o correcciones pequeñas `fix:` verificadas).
* **Cuándo sí abrir rama:** Solo para frentes que requieran varios commits, rompan temporalmente simulación/síntesis o sean variantes experimentales aparte (ej. `feat/fault-injector`, `feat/debug-module`). Al verificar, fusionar a `main` y borrar la rama salvo indicación contraria.
* **Commits:** Mensajes breves con prefijo claro (`feat:`, `tb:`, `fix:`, `docs:`, `build:`, `refactor:`).