#!/usr/bin/env python3
"""Analizador de resultados SEU para HPicoRV32 (taxonomía Travessini + vista HARV + profiling)."""

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path

CATS_5 = ("No_Effect", "Latent", "Wrong_Result", "Timed_Out", "Exception")
HARMFUL = {"Wrong_Result", "Timed_Out", "Exception"}


def load_rows(csv_path: Path):
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def pct(n: int, total: int) -> str:
    return f"{(100.0 * n / total):5.1f}%" if total else "  0.0%"


def summarize_subset(title: str, rows):
    n = len(rows)
    if n == 0:
        print(f"  [{title}] sin filas.")
        return

    c = Counter(r["outcome"] for r in rows)
    match = c["No_Effect"] + c["Latent"]
    harmful = c["Wrong_Result"] + c["Timed_Out"] + c["Exception"]
    reg_logic_err = sum(1 for r in rows if r["regs_logic_match"] == "0" or r["pc_match"] == "0")
    reg_phys_err = sum(1 for r in rows if r["regs_phys_match"] == "0" or r["pc_match"] == "0")
    telem_act = sum(1 for r in rows if r["telem_changed"] == "1")

    print(f"  [{title}] N={n}")
    print("    5 cat. (Travessini): "
          + " | ".join(f"{k}={c[k]} ({pct(c[k], n)})" for k in CATS_5))
    print(f"    3 cat. (UART/HARV):  Match={match} ({pct(match, n)}) | "
          f"Mismatch={c['Wrong_Result']} ({pct(c['Wrong_Result'], n)}) | "
          f"Hang={c['Timed_Out']} ({pct(c['Timed_Out'], n)}) | "
          f"Trap/Exc={c['Exception']} ({pct(c['Exception'], n)}) | "
          f"Total dañinos={harmful} ({pct(harmful, n)})")
    print(f"    Registros / Telem.:  ArchErr(32b)={reg_logic_err} ({pct(reg_logic_err, n)}) | "
          f"PhysErr(39b)={reg_phys_err} ({pct(reg_phys_err, n)}) | "
          f"TelemTMR/ECC>0={telem_act} ({pct(telem_act, n)})")

