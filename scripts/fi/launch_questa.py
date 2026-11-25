#!/usr/bin/env python3
"""Orquestador paralelo de campañas SEU en Questa 2025.2 para HPicoRV32."""

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

RTL_GLOBS = ("rtl/core/*.v", "rtl/mem/*.v", "rtl/periph/*.v", "rtl/top/*.v")


def run_checked(cmd, desc: str):
    print(f"[build] {desc}...")
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if res.returncode != 0:
        print(res.stdout)
        sys.exit(f"ERROR en '{desc}' (exit {res.returncode})")


def prepare_questa_lib(lib_dir: Path, tmr: int, ecc: int):
    if lib_dir.exists():
        shutil.rmtree(lib_dir)
    lib_dir.parent.mkdir(parents=True, exist_ok=True)

    rtl_files = ["tb/tb_fi_soc.v"]
    for pattern in RTL_GLOBS:
        rtl_files.extend(sorted(str(p) for p in Path(".").glob(pattern)))

    run_checked(["vlib", str(lib_dir)], f"vlib {lib_dir}")
    run_checked(["vlog", "-work", str(lib_dir)] + rtl_files, "vlog RTL + tb_fi_soc.v")
    run_checked(
        [
            "vopt", "-work", str(lib_dir), "-L", str(lib_dir),
            "+acc=rn",
            f"-GENABLE_TMR={tmr}",
            f"-GENABLE_REG_ECC={ecc}",
            "tb_fi_soc", "-o", "opt_tb",
        ],
        f"vopt TMR={tmr} ECC={ecc}",
    )


def split_runs(total: int, workers: int):
    """Reparte 'total' corridas equilibradamente entre 'workers' -> [(offset, count), ...]."""
    workers = max(1, min(workers, total))
    base, rem = divmod(total, workers)
    chunks = []
    offset = 0
    for i in range(workers):
        cnt = base + (1 if i < rem else 0)
        chunks.append((offset, cnt))
        offset += cnt
    return chunks