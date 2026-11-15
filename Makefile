# ==============================================================================
# Makefile raíz — SHRV32 (Space-Hardened RISC-V 32)
# ==============================================================================

BUILD_DIR   := build
VIVADO_DIR  := $(BUILD_DIR)/vivado
OPENXC7_DIR := $(BUILD_DIR)/openxc7
TCL_DIR     := fpga/nexys_a7
XDC_FILE    := $(TCL_DIR)/Nexys-A7-100T-Master.xdc

RTL_SRCS    := $(wildcard rtl/core/*.v rtl/mem/*.v rtl/periph/*.v rtl/top/*.v)
TB          ?= tb/tb_soc.v
PORT        ?= /dev/ttyUSB1
APP         ?= counter
FW          ?= counter
SIM_FAST    ?= 0

SYNTH       ?= vivado
FPGA_PART   := xc7a100tcsg324-1
FPGA_DIE    := xc7a100t
FPGA_FAMILY := artix7
CHIPDB_DIR  ?= $(HOME)/.cache/openxc7
CHIPDB_BIN  := $(CHIPDB_DIR)/chipdb-$(FPGA_PART).bin

ifeq ($(SYNTH),openxc7)
BIT_FILE := $(OPENXC7_DIR)/shrv32.bit
else
BIT_FILE := $(VIVADO_DIR)/shrv32.bit
endif

.PHONY: help sw upload sim wave lint synth vivado-gui prog clean

help:
	@echo "Comandos disponibles en SHRV32:"
	@echo "  make sw [FW=counter|boot] -> Compila bootloader + app y genera build/firmware.hex"
	@echo "  make upload [PORT=...]    -> Sube build/$(APP).bin al bootloader vía UART"
	@echo "  make sim [TB=...]         -> Compila firmware y simula con iverilog"
	@echo "  make wave                 -> Abre build/dump.vcd en Surfer"
	@echo "  make lint                 -> Comprueba sintaxis y reglas RTL con Verilator"
	@echo "  make synth [SYNTH=vivado|openxc7] -> Síntesis, P&R y bitstream"
	@echo "  make vivado-gui           -> Genera el .xpr y abre la interfaz gráfica de Vivado"
	@echo "  make prog [SYNTH=vivado|openxc7]  -> Programa la Nexys A7 usando openFPGALoader"
	@echo "  make clean                -> Elimina la carpeta build/"

sw:
	@mkdir -p $(BUILD_DIR)
	$(MAKE) -C sw FW=$(FW) SIM_FAST=$(SIM_FAST)

upload: sw
	python3 sw/common/upload.py $(BUILD_DIR)/$(APP).bin $(PORT)

sim: sw
	@mkdir -p $(BUILD_DIR)
	iverilog -g2001 -o $(BUILD_DIR)/sim.out $(TB) $(RTL_SRCS)
	vvp $(BUILD_DIR)/sim.out

wave:
	surfer $(BUILD_DIR)/dump.vcd &

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSED -Wno-UNDRIVEN -Wno-PINCONNECTEMPTY \
		-Wno-PINMISSING -Wno-BLKSEQ -Wno-GENUNNAMED -Wno-PROCASSINIT -Wno-WIDTHTRUNC \
		-Wno-WIDTHEXPAND -Wno-SYNCASYNCNET --top-module soc $(RTL_SRCS)

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
	cd $(OPENXC7_DIR) && yosys -l yosys.log -Q \
		-p 'synth_xilinx -flatten -abc9 -arch xc7 -top soc; write_json soc.json' \
		$(abspath $(RTL_SRCS))
	nextpnr-xilinx --chipdb $(CHIPDB_BIN) \
		--xdc $(XDC_FILE) \
		--json $(OPENXC7_DIR)/soc.json \
		--fasm $(OPENXC7_DIR)/soc.fasm \
		-l $(OPENXC7_DIR)/nextpnr.log
	fasm2frames --db-root "$$PRJXRAY_DB_DIR/$(FPGA_FAMILY)" \
		--part $(FPGA_PART) $(OPENXC7_DIR)/soc.fasm $(OPENXC7_DIR)/soc.frames
	xc7frames2bit --part_file "$$PRJXRAY_DB_DIR/$(FPGA_FAMILY)/$(FPGA_PART)/part.yaml" \
		--part_name $(FPGA_PART) \
		--frm_file $(OPENXC7_DIR)/soc.frames \
		--output_file $(OPENXC7_DIR)/shrv32.bit
else
synth: sw
	@mkdir -p $(VIVADO_DIR)
	vivado -mode batch \
		-source $(TCL_DIR)/build.tcl \
		-log $(VIVADO_DIR)/build.log \
		-journal $(VIVADO_DIR)/build.jou
endif

vivado-gui: sw
	@mkdir -p $(VIVADO_DIR)
	vivado -mode batch \
		-source $(TCL_DIR)/create_project.tcl \
		-log $(VIVADO_DIR)/create.log \
		-journal $(VIVADO_DIR)/create.jou
	vivado $(VIVADO_DIR)/shrv32.xpr \
		-log $(VIVADO_DIR)/gui.log \
		-journal $(VIVADO_DIR)/gui.jou &

prog:
	openFPGALoader -b nexys_a7_100 $(BIT_FILE)

clean:
	rm -rf $(BUILD_DIR)
