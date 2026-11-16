#!/usr/bin/env python3
"""Convierte un binario RISC-V raw (.bin) en formato .hex de palabras de 32 bits para $readmemh."""

from sys import argv

HSIAO_MASKS = (
    0x00003FFF,  # P0
    0x00FFC00F,  # P1
    0x1F03C0F1,  # P2
    0xE31C4712,  # P3
    0x6D649924,  # P4
    0xB6A92A40,  # P5
    0xD8D23488,  # P6
)


def encode_hsiao_39(word32: int) -> int:
    ecc = 0
    for bit, mask in enumerate(HSIAO_MASKS):
        parity = bin(word32 & mask).count("1") & 1
        ecc |= parity << bit
    return (ecc << 32) | (word32 & 0xFFFFFFFF)


ecc_mode = "--ecc" in argv[1:]
pos_args = [a for a in argv[1:] if a != "--ecc"]

binfile = pos_args[0]
nwords = int(pos_args[1])
coefile = pos_args[2] if len(pos_args) > 2 else None

with open(binfile, "rb") as f:
    bindata = f.read()

while len(bindata) % 4 != 0:
    bindata += b"\x00"

assert len(bindata) <= 4 * nwords, (
    f"Firmware ({len(bindata)} B) excede la capacidad de memoria ({4 * nwords} B)"
)

words = []
for i in range(nwords):
    if i < len(bindata) // 4:
        w = bindata[4 * i : 4 * i + 4]
        val = int.from_bytes(w, "little")
    else:
        val = 0
    if ecc_mode:
        words.append("%010x" % encode_hsiao_39(val))
    else:
        words.append("%08x" % val)

for w in words:
    print(w)

if coefile:
    with open(coefile, "w") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        f.write(",\n".join(words))
        f.write(";\n")
