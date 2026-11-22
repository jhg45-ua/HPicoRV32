# ==============================================================================
# Makefile raíz — HPicoRV32 (Hardened PicoRV32)
# ==============================================================================

BUILD_DIR   := build
VIVADO_DIR  := $(BUILD_DIR)/vivado
OPENXC7_DIR := $(BUILD_DIR)/openxc7
TCL_DIR     := fpga/nexys_a7
# FI=0 genera el diseño limpio de vuelo (soc); FI=1 genera la demo interactiva en placa (soc_fi_top)
FI          ?= 0
ifeq ($(FI),1)
SYNTH_TOP   := soc_fi_top
XDC_FILE    := $(TCL_DIR)/Nexys-A7-100T-FI.xdc
else
SYNTH_TOP   := soc
XDC_FILE    := $(TCL_DIR)/Nexys-A7-100T-Master.xdc
endif

RTL_SRCS    := $(wildcard rtl/core/*.v rtl/mem/*.v rtl/periph/*.v rtl/top/*.v)
TB          ?= tb/tb_soc.v
APP         ?= counter
# Si ejecutas tb_fault_campaign sin pasar APP= explícitamente, selecciona fi_bench automáticamente
ifeq ($(origin APP),file)
ifeq ($(filter tb/tb_fault_campaign.v,$(TB)),tb/tb_fault_campaign.v)
override APP := fi_bench
endif
endif
# Si vale 1, define -DSIM_FAST en sw/Makefile para acortar HEARTBEAT_DELAY y acelerar UART en simulación
SIM_FAST    ?= 0
# Plusargs opcionales pasados al simulador (p. ej. SIM_ARGS="+NUM_RUNS=100")
SIM_ARGS    ?=

SYNTH       ?= vivado
FPGA_PART   := xc7a100tcsg324-1
FPGA_DIE    := xc7a100t
FPGA_FAMILY := artix7
CHIPDB_DIR  ?= $(HOME)/.cache/openxc7
CHIPDB_BIN  := $(CHIPDB_DIR)/chipdb-$(FPGA_PART).bin

ifeq ($(SYNTH),openxc7)
BIT_FILE := $(OPENXC7_DIR)/hpicorv32.bit
else
BIT_FILE := $(VIVADO_DIR)/hpicorv32.bit
endif

SIM         ?= iverilog
TRACE       ?= 1
TB_TOP      ?= $(basename $(notdir $(TB)))
VLT_PROCASSINIT_FLAG := $(shell verilator -Wno-PROCASSINIT --version >/dev/null 2>&1 && echo -Wno-PROCASSINIT)
VLT_WARN_FLAGS := -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PINCONNECTEMPTY \
	-Wno-PINMISSING -Wno-BLKSEQ -Wno-GENUNNAMED $(VLT_PROCASSINIT_FLAG) \
	-Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET

.PHONY: help sw sim wave lint synth vivado-gui prog clean

help:
	@echo "Comandos disponibles en HPicoRV32:"
	@echo "  make sw [APP=counter] [SIM_FAST=1|0]                   -> Compila sw/apps/<APP> y genera build/firmware.hex"
	@echo "  make sim [TB=...] [APP=...] [SIM=iverilog|verilator] [TRACE=1|0] -> Compila firmware y simula RTL"
	@echo "  make wave                                              -> Abre build/dump.vcd en Surfer"
	@echo "  make lint                                              -> Comprueba sintaxis y reglas RTL con Verilator (soc y soc_fi_top)"
	@echo "  make synth [SYNTH=vivado|openxc7] [FI=0|1]             -> Síntesis, P&R y bitstream (FI=1: demo Nexys A7)"
	@echo "  make vivado-gui [FI=0|1]                               -> Genera el .xpr y abre la interfaz gráfica de Vivado"
	@echo "  make prog [SYNTH=vivado|openxc7]                       -> Programa la Nexys A7 usando openFPGALoader"
	@echo "  make clean                                             -> Elimina la carpeta build/"

sw:
	@mkdir -p $(BUILD_DIR)
# Fuerza recompilación (-B) para que cambiar entre SIM_FAST=0 y SIM_FAST=1 nunca deje un .hex obsoleto
	$(MAKE) -B -C sw APP=$(APP) SIM_FAST=$(SIM_FAST)

# Compila firmware automáticamente si el testbench carga build/firmware.hex (tb_soc o tb_fault_campaign)
SIM_DEPS := $(if $(filter tb/tb_soc.v tb/tb_fault_campaign.v,$(TB)),sw,)
sim: $(SIM_DEPS)
	@mkdir -p $(BUILD_DIR)
ifeq ($(SIM), verilator)
	verilator --binary $(if $(filter 1,$(TRACE)),--trace,) -j 0 $(VLT_WARN_FLAGS) \
		--Mdir $(BUILD_DIR)/vlt_$(TB_TOP) --top-module $(TB_TOP) $(TB) $(RTL_SRCS)
	./$(BUILD_DIR)/vlt_$(TB_TOP)/V$(TB_TOP) $(SIM_ARGS)
else ifeq ($(SIM), iverilog)
	iverilog -g2001 -o $(BUILD_DIR)/sim.out $(TB) $(RTL_SRCS)
	vvp $(BUILD_DIR)/sim.out $(SIM_ARGS)
else
	$(error Simulador no soportado: '$(SIM)'. Usa SIM=iverilog o SIM=verilator)
endif

wave:
	surfer $(BUILD_DIR)/dump.vcd &

lint:
	verilator --lint-only -Wall $(VLT_WARN_FLAGS) --top-module soc $(RTL_SRCS)
	verilator --lint-only -Wall $(VLT_WARN_FLAGS) --top-module soc_fi_top $(RTL_SRCS)

$(CHIPDB_BIN):
	@if [ -z "$$NEXTPNR_XILINX_DIR" ] || [ -z "$$PRJXRAY_DB_DIR" ]; then \
		echo "Error: carga primero el entorno con 'source /opt/openxc7/export.sh'"; exit 1; \
	fi
	@mkdir -p $(CHIPDB_DIR)
	python3 "$$NEXTPNR_XILINX_DIR/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py" \
		--xray "$$PRJXRAY_DB_DIR/$(FPGA_FAMILY)" --device $(FPGA_DIE) \
		--bba $(CHIPDB_DIR)/chipdb-$(FPGA_DIE).bba
	bbasm -l $(CHIPDB_DIR)/chipdb-$(FPGA_DIE).bba $@.tmp
	mv $@.tmp $@
	@rm -f $(CHIPDB_DIR)/chipdb-$(FPGA_DIE).bba

ifeq ($(SYNTH),openxc7)
synth: sw $(CHIPDB_BIN)
	@if [ -z "$$PRJXRAY_DB_DIR" ]; then \
		echo "Error: carga primero el entorno con 'source /opt/openxc7/export.sh'"; exit 1; \
	fi
	@mkdir -p $(OPENXC7_DIR)
	cp $(BUILD_DIR)/firmware.hex $(OPENXC7_DIR)/firmware.hex
# Propaga 'keep' desde los registros TMR (* keep *) hacia sus celdas FF antes de opt_merge
	cd $(OPENXC7_DIR) && yosys -l yosys.log -Q \
		-p 'hierarchy -check -top $(SYNTH_TOP); proc; setattr -set keep 1 a:keep %ci1 t:*dff* %i; synth_xilinx -flatten -abc9 -arch xc7 -top $(SYNTH_TOP); write_json soc.json' \
		$(abspath $(RTL_SRCS))
# --tmg-ripup re-enruta cables críticos que superen 10 ns (clave para que FI=1 cierre a 100 MHz)
	nextpnr-xilinx --chipdb $(CHIPDB_BIN) \
		--tmg-ripup \
		--xdc $(XDC_FILE) \
		--json $(OPENXC7_DIR)/soc.json \
		--fasm $(OPENXC7_DIR)/soc.fasm \
		-l $(OPENXC7_DIR)/nextpnr.log
	fasm2frames --db-root "$$PRJXRAY_DB_DIR/$(FPGA_FAMILY)" \
		--part $(FPGA_PART) $(OPENXC7_DIR)/soc.fasm $(OPENXC7_DIR)/soc.frames
	xc7frames2bit --part_file "$$PRJXRAY_DB_DIR/$(FPGA_FAMILY)/$(FPGA_PART)/part.yaml" \
		--part_name $(FPGA_PART) \
		--frm_file $(OPENXC7_DIR)/soc.frames \
		--output_file $(OPENXC7_DIR)/hpicorv32.bit
else
synth: sw
	@mkdir -p $(VIVADO_DIR)
	vivado -mode batch \
		-source $(TCL_DIR)/build.tcl \
		-tclargs $(FI) \
		-log $(VIVADO_DIR)/build.log \
		-journal $(VIVADO_DIR)/build.jou
endif

vivado-gui: sw
	@mkdir -p $(VIVADO_DIR)
	vivado -mode batch \
		-source $(TCL_DIR)/create_project.tcl \
		-tclargs $(FI) \
		-log $(VIVADO_DIR)/create.log \
		-journal $(VIVADO_DIR)/create.jou
	vivado $(VIVADO_DIR)/hpicorv32.xpr \
		-log $(VIVADO_DIR)/gui.log \
		-journal $(VIVADO_DIR)/gui.jou &

prog:
	openFPGALoader -b nexys_a7_100 $(BIT_FILE)

clean:
	rm -rf $(BUILD_DIR)
