# HPicoRV32 — Hardened PicoRV32 SoC

**HPicoRV32** es un *System-on-Chip* (SoC) tolerante a fallos basado en el núcleo **PicoRV32** (RV32I, interfaz de memoria nativa sin AXI), diseñado para mitigar *bit-flips* inducidos por radiación (*Single Event Upsets* / SEUs) en entornos espaciales.

El procesador está concebido como núcleo de control dentro de una IP aceleradora de red neuronal para aplicaciones aeroespaciales.

---

## Arquitectura y Técnicas de Endurecimiento

* **TMR 2-de-3 con *self-healing*:** Triplicación física y votación mayoritaria combinacional (`tmr_voter.v`) con reparación síncrona en 1 ciclo sobre `reg_pc`, `reg_next_pc`, `cpu_state`, `mem_state` y `latched_rd`, más contadores de telemetría por CSR (`0xCC0` / `0xCC1`).
* **Arquitectura Harvard con política `W^X`:** Desacoplamiento estricto en **IMEM** (`0x0000_0000–0x0000_1FFF`, 8 KB R/X con precarga de `firmware.hex` y escritura bloqueada) y **DMEM** (`0x0000_2000–0x0000_3FFF`, 8 KB R/W exclusiva para datos). Cualquier intento de escritura en IMEM o ejecución desde DMEM activa `harv_err` y enclava `trap`.
* **ECC Hsiao SEC-DED (39,32) completo:**
  * **Banco de registros `cpuregs`:** Ampliado a `32 × 39` bits preservando inferencia de LUTRAM, con *auto-scrubbing* oportunista en 1 ciclo, filtrado de falsos positivos en lecturas especulativas y CSRs `0xCC2` (`SBU`) / `0xCC3` (`DBU`).
  * **IMEM y DMEM (`bram_ecc.v`):** Corrección de error simple (`SBE`) con *auto-scrubbing* interno (incluso en IMEM de solo lectura externa), protocolo *Read-Modify-Write* (RMW) para escrituras parciales `sb`/`sh`, parada segura (`trap`) ante error doble (`DBE`), backend dual RTL portable / IP *Soft ECC* (`blk_mem_gen`) en Vivado y contadores MMIO en `0x3000_0000–0x3000_000C`.
* **Configurabilidad:** Parámetros `IMEM_WORDS`, `DMEM_WORDS`, `ENABLE_TMR` y `ENABLE_REG_ECC` expuestos en `rtl/top/soc.v`.
* **Hardware objetivo:**
  * *Prototipado activo:* Digilent Nexys A7-100T (AMD Xilinx Artix-7 `xc7a100tcsg324-1`).
  * *Despliegue futuro:* Microchip PolarFire FPGA (Verilog-2001 estándar y portable en `rtl/`).

---

## Estructura del Repositorio

```text
HPicoRV32/
├── AGENTS.md          # Contexto técnico, guía de Verilog y reglas de flujo
├── Makefile           # Flujo unificado de simulación, firmware, Vivado y openXC7
├── external/          # Submódulos Git de solo lectura (picorv32 y harv)
├── rtl/               # RTL Verilog sintetizable (core, mem, periph, top)
├── tb/                # Bancos de pruebas unitarios e integral con inyección XOR
├── sw/                # Firmware bare-metal RISC-V (arranque Harvard y apps)
├── fpga/nexys_a7/     # Restricciones de placa (.xdc) y scripts Tcl de Vivado
└── docs/              # Bitácora técnica, notas sobre HARV y diagramas
```

---

## Primeros Pasos

### 1. Clonar el repositorio con submódulos

```bash
git clone --recursive https://github.com/jhg45-ua/HPicoRV32.git
cd HPicoRV32
```

### 2. Comandos de compilación y simulación (`Makefile`)

| Comando | Descripción |
| --- | --- |
| `make sw` | Compila `sw/boot/crt0.S` y `sw/apps/$(APP)/` con codificación Hsiao (`--ecc`), generando `build/firmware.hex` |
| `make sim` | Ejecuta el testbench seleccionado (`TB`); compila firmware automáticamente si `TB=tb/tb_soc.v` |
| `make wave` | Abre las formas de onda generadas (`build/dump.vcd`) en **Surfer** |
| `make lint` | Comprueba sintaxis y reglas RTL con **Verilator** |
| `make synth` | Ejecuta síntesis, P&R y *bitstream* con **Vivado** (`SYNTH=vivado`) o **openXC7** (`SYNTH=openxc7`) |
| `make vivado-gui` | Genera el proyecto `.xpr` en `build/vivado/` y abre la GUI de Vivado |
| `make prog` | Programa la placa Nexys A7-100T mediante `openFPGALoader -b nexys_a7_100` (usa `SYNTH` para elegir el `.bit`) |
| `make clean` | Elimina todos los artefactos generados dentro de `build/` |

### 3. Opciones y *flags* del `Makefile`

Puedes pasar estas variables al invocar `make` (por ejemplo: `make sim SIM_FAST=1`, `make sim SIM=verilator TRACE=0`, `make sim TB=tb/tb_tmr_voter.v` o `make synth SYNTH=openxc7`):

| Variable | Por defecto | Para qué sirve |
| --- | --- | --- |
| `APP` | `counter` | Aplicación en `sw/apps/$(APP)/` compilada hacia `build/firmware.hex`. |
| `SIM_FAST` | `0` | Si vale `1`, compila la app con `-DSIM_FAST` reduciendo `HEARTBEAT_DELAY` de `250000` a `50` ciclos para acelerar la simulación. **Usar `0` para la FPGA real.** |
| `SIM` | `iverilog` | Selecciona el simulador RTL para `make sim`: `iverilog` (4 estados: `0`/`1`/`X`/`Z`) o `verilator` (`--binary`, compilado a C++ para simulaciones rápidas). |
| `TRACE` | `1` | Solo con `SIM=verilator`: `1` activa `--trace` y genera `build/dump.vcd`; `0` omite el volcado VCD para acelerar ejecuciones largas cuando solo interesa la consola UART. |
| `TB` | `tb/tb_soc.v` | Selecciona el *testbench* a ejecutar en `make sim` (p. ej. `make sim TB=tb/tb_tmr_voter.v`, `tb/tb_ecc_secded.v` o `tb/tb_bram_ecc.v`). |
| `TB_TOP` | `$(basename $(notdir $(TB)))` | Módulo raíz (`--top-module`) pasado a Verilator; por defecto se deduce del nombre del fichero `TB` sin extensión (p. ej. `tb_soc`). |
| `TOOLCHAIN` | `riscv64-unknown-elf-` | Prefijo del compilador cruzado RISC-V en `sw/Makefile`. |
| `SYNTH` | `vivado` | *Backend* de implementación y *bitstream*: `vivado` genera `build/vivado/hpicorv32.bit`; `openxc7` usa `yosys` + `nextpnr-xilinx` + `fasm2frames` + `xc7frames2bit` y genera `build/openxc7/hpicorv32.bit`. |
| `CHIPDB_DIR` | `$(HOME)/.cache/openxc7` | Directorio de caché para `chipdb-xc7a100tcsg324-1.bin` en el flujo `SYNTH=openxc7`. |

> **Nota sobre simuladores:** **Verilator** simula en 2 estados (`0` y `1`) e inicializa los registros a `0` por defecto, por lo que no propaga `X`/`Z`. Úsalo para iterar rápido, pero valida también los módulos nuevos con **Icarus Verilog** (`SIM=iverilog`) para detectar posibles registros sin *reset* o memorias sin inicializar.

> **Nota histórica (`sw/boot/bootloader.c` y `sw/common/upload.py`):** Estos ficheros se conservan únicamente como referencia histórica de la etapa pre-Harvard, cuando la memoria era unificada y el bootloader cargaba binarios por UART hacia `0x0000_0800`. En la arquitectura Harvard actual con protección `W^X` sobre `IMEM`, el firmware se empaqueta directamente en `build/firmware.hex`.

### 4. Flujo de síntesis Open Source (`SYNTH=openxc7`)

Pensado para generar y programar el *bitstream* nativamente en macOS/Linux sin depender de Vivado (la primera ejecución compila y cachea `chipdb-xc7a100tcsg324-1.bin` en `CHIPDB_DIR`):

```bash
source /opt/openxc7/export.sh
make synth SYNTH=openxc7
make prog SYNTH=openxc7
```

*(Requiere tener instalado **openXC7** en `/opt/openxc7`, con `NEXTPNR_XILINX_DIR` y `PRJXRAY_DB_DIR` exportados al cargar `export.sh`.)*

---

## Documentación

* **Notas de desarrollo y diagramas:** En [`docs/`](docs/) (`logbook.md`, notas arquitectónicas de HARV y diagramas editables).
* **Memoria técnica formal (Oleafy):** *[Enlace al documento en Oleafy]*

---

## Referencias y Licencia

* Basado en [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (Licencia ISC).
* Referencia de arquitectura tolerante a radiación: [xarc/harv](https://github.com/xarc/harv).
* Publicado bajo **Licencia MIT** (ver [`LICENSE`](LICENSE) para más detalles).
