# SHRV32 — Space-Hardened RISC-V 32 SoC

**SHRV32** es un *System-on-Chip* (SoC) tolerante a fallos basado en el núcleo **PicoRV32** (RV32I, interfaz de memoria nativa sin AXI), diseñado para mitigar *bit-flips* inducidos por radiación (*Single Event Upsets* / SEUs) en entornos espaciales.

El procesador está concebido como núcleo de control dentro de una IP aceleradora de red neuronal para aplicaciones aeroespaciales.

---

## Arquitectura y Técnicas de Endurecimiento

* **Triple Modular Redundancy (TMR):** Triplicación física con votador mayoritario 2-de-3 aplicada al contador de programa (`reg_pc`) y registros críticos de control.
* **Bus Harvard desacoplado:** Separación de los buses de instrucciones y datos a partir de la señal `mem_instr` del núcleo.
* **Memoria de datos protegida con ECC:** Protección SECDED (*Single Error Correction, Double Error Detection*) con banderas de estado `sbiterr` y `dbiterr`.
* **Hardware objetivo:**
  * *Prototipado activo:* Digilent Nexys A7-100T (AMD Xilinx Artix-7 `xc7a100tcsg324-1`).
  * *Despliegue futuro:* Microchip PolarFire FPGA (escrito en Verilog-2001 estándar y portable).

---

## Estructura del Repositorio

```text
shrv32/
├── AGENTS.md          # Contexto técnico, guía de Verilog y reglas de flujo
├── Makefile           # Flujo unificado de simulación, firmware y Vivado
├── external/          # Submódulos Git de solo lectura (picorv32 y harv)
├── rtl/               # RTL Verilog sintetizable (core, mem, periph, top)
├── tb/                # Bancos de pruebas e inyección de fallos XOR
├── sw/                # Firmware bare-metal RISC-V (bootloader y apps)
├── fpga/nexys_a7/     # Restricciones de placa (.xdc) y scripts Tcl de Vivado
└── docs/              # Bitácora técnica, notas sobre HARV y diagramas
```

---

## Primeros Pasos

### 1. Clonar el repositorio con submódulos

```bash
git clone --recursive https://github.com/jhg45-ua/shrv32.git
cd shrv32
```

### 2. Comandos de compilación y simulación (`Makefile`)

| Comando | Descripción |
| --- | --- |
| `make sw` | Compila el bootloader y la app de contador, generando `build/firmware.hex` |
| `make upload` | Envía `build/$(APP).bin` por UART al bootloader (`PORT=/dev/ttyUSB1`) |
| `make sim` | Compila el firmware y ejecuta la simulación RTL con **Icarus Verilog** (`SIM=iverilog`) o **Verilator** (`SIM=verilator`) |
| `make wave` | Abre las formas de onda generadas (`build/dump.vcd`) en **Surfer** |
| `make lint` | Comprueba sintaxis y reglas de diseño RTL con **Verilator** |
| `make synth` | Ejecuta síntesis, implementación y bitstream en **Vivado** (modo batch) |
| `make vivado-gui` | Genera el proyecto `.xpr` en `build/vivado/` y abre la GUI de Vivado |
| `make prog` | Programa la placa Nexys A7-100T mediante `openFPGALoader` |
| `make clean` | Elimina todos los artefactos generados dentro de `build/` |

### 3. Opciones y *flags* del `Makefile`

Puedes pasar estas variables al invocar `make` (por ejemplo: `make sim SIM_FAST=1`, `make sim SIM=verilator TRACE=0` o `make sw FW=boot`):

| Variable | Por defecto | Para qué sirve |
| --- | --- | --- |
| `FW` | `counter` | Elige qué firmware se copia en `build/firmware.hex` (dirección `0x0`): `counter` arranca el contador directamente; `boot` carga el *bootloader* UART para recibir programas en `0x800`. |
| `SIM_FAST` | `0` | Si vale `1`, compila la app con `-DSIM_FAST` reduciendo `HEARTBEAT_DELAY` de `250000` a `50` ciclos para ver avances en simulación sin esperar segundos reales. **Usar `0` para la FPGA real.** |
| `SIM` | `iverilog` | Selecciona el simulador RTL para `make sim`: `iverilog` (4 estados: `0`/`1`/`X`/`Z`) o `verilator` (`--binary`, compilado a C++ para simulaciones rápidas). |
| `TRACE` | `1` | Solo con `SIM=verilator`: `1` activa `--trace` y genera `build/dump.vcd`; `0` omite el volcado VCD para acelerar ejecuciones largas cuando solo interesa la consola UART. |
| `TB` | `tb/tb_soc.v` | Selecciona el *testbench* a ejecutar en `make sim` (útil para bancos unitarios, p. ej. `make sim TB=tb/tb_tmr_voter.v`). |
| `TB_TOP` | `$(basename $(notdir $(TB)))` | Módulo raíz (`--top-module`) pasado a Verilator; por defecto se deduce del nombre del fichero `TB` sin extensión (p. ej. `tb_soc`). |
| `APP` | `counter` | Nombre del binario `build/$(APP).bin` que sube `make upload`. |
| `PORT` | `/dev/ttyUSB1` | Puerto serie USB-UART de la Nexys A7 para `make upload` (en macOS suele ser `/dev/cu.usbserial-*`). |
| `TOOLCHAIN` | `riscv64-unknown-elf-` | Prefijo del compilador cruzado RISC-V en `sw/Makefile`. |

> **Nota sobre simuladores:** **Verilator** simula en 2 estados (`0` y `1`) e inicializa los registros a `0` por defecto, por lo que no propaga `X`/`Z`. Úsalo para iterar rápido, pero valida también los módulos nuevos con **Icarus Verilog** (`SIM=iverilog`) para detectar posibles registros sin *reset* o memorias sin inicializar.

---

## Documentación

* **Notas de desarrollo y diagramas:** En [`docs/`](docs/) (`logbook.md`, notas arquitectónicas de HARV y diagramas editables).
* **Memoria técnica formal (Oleafy):** *[Enlace al documento en Oleafy]*

---

## Referencias y Licencia

* Basado en [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) (Licencia ISC).
* Referencia de arquitectura tolerante a radiación: [xarc/harv](https://github.com/xarc/harv).
* Publicado bajo **Licencia MIT** (ver [`LICENSE`](LICENSE) para más detalles).
