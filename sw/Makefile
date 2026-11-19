# ==============================================================================
# Makefile de Firmware — HPicoRV32 (Hardened PicoRV32)
# Compila sw/boot/crt0.S y sw/apps/$(APP)/, generando ../build/firmware.hex
# ==============================================================================

TOOLCHAIN ?= riscv64-unknown-elf-
BUILD_DIR := ../build
MEM_WORDS := 2048

# Aplicación en sw/apps/$(APP)/ y flag de simulación rápida
APP       ?= counter
SIM_FAST  ?= 0

CFLAGS    := -Os -mabi=ilp32 -march=rv32i -ffreestanding -nostdlib --std=gnu99
ifeq ($(SIM_FAST),1)
CFLAGS    += -DSIM_FAST
endif

LDFLAGS   := -Wl,-Bstatic,-T,boot/sections.ld,--strip-debug
LIBS      := -lgcc

CRT0        := boot/crt0.S
LDS         := boot/sections.ld
COMMON_HDRS := $(wildcard common/*.h)
APP_SRCS    := $(wildcard apps/$(APP)/*.c)
APP_HDRS    := $(wildcard apps/$(APP)/*.h)
MAKEHEX     := common/makehex.py

ifeq ($(APP_SRCS),)
$(error No se encontraron fuentes .c en sw/apps/$(APP)/)
endif

.PHONY: all clean force_cfg

all: $(BUILD_DIR)/firmware.hex

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Registra APP y SIM_FAST activos para recompilar automáticamente si cambia alguno
CFG_FILE := $(BUILD_DIR)/.sw_cfg
$(CFG_FILE): force_cfg | $(BUILD_DIR)
	@echo "APP=$(APP) SIM_FAST=$(SIM_FAST)" > $@.tmp
	@cmp -s $@.tmp $@ 2>/dev/null || mv $@.tmp $@
	@rm -f $@.tmp

# Firmware autónomo Harvard (código + .rodata en IMEM, datos + pila en DMEM)
$(BUILD_DIR)/$(APP).elf: $(CRT0) $(APP_SRCS) $(APP_HDRS) $(COMMON_HDRS) $(LDS) $(CFG_FILE) | $(BUILD_DIR)
	$(TOOLCHAIN)gcc $(CFLAGS) $(CRT0) $(APP_SRCS) \
		$(LDFLAGS),-Map,$(BUILD_DIR)/$(APP).map $(LIBS) -o $@
	@$(TOOLCHAIN)size $@

$(BUILD_DIR)/$(APP).bin: $(BUILD_DIR)/$(APP).elf
	$(TOOLCHAIN)objcopy -O binary $< $@

$(BUILD_DIR)/firmware.hex: $(BUILD_DIR)/$(APP).bin $(MAKEHEX)
	python3 $(MAKEHEX) $< $(MEM_WORDS) --ecc > $@

clean:
	rm -f $(BUILD_DIR)/*.elf $(BUILD_DIR)/*.bin $(BUILD_DIR)/*.hex $(BUILD_DIR)/*.map
