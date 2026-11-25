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

def print_profiling(rows, top_n: int, show_failures: bool):
    # Agrupa impactos por dominio y por registro (en 10-SEU cada registro inyectado suma 1)
    by_dom = defaultdict(lambda: Counter())
    by_reg = defaultdict(lambda: Counter())

    for r in rows:
        out = r["outcome"]
        regs = r["inj_regs"].split(";")
        doms = r["inj_domains"].split(";")
        # Usamos set() por corrida para no contar dos veces el mismo registro/dominio en 10-SEU
        for d in set(doms):
            by_dom[d][out] += 1
            by_dom[d]["_tot"] += 1
        for reg in set(regs):
            by_reg[reg][out] += 1
            by_reg[reg]["_tot"] += 1

    print("\n  Desglose por dominio (ordenado por fallos dañinos):")
    dom_sorted = sorted(
        by_dom.items(),
        key=lambda kv: (sum(kv[1][h] for h in HARMFUL), kv[1]["_tot"]),
        reverse=True,
    )
    print(f"    {'Dominio':16s} {'Tot':>4s} {'NoEff':>5s} {'Lat':>4s} {'Wrong':>5s} {'Tout':>4s} {'Exc':>4s}")
    for dom, cnt in dom_sorted:
        print(f"    {dom:16s} {cnt['_tot']:4d} {cnt['No_Effect']:5d} {cnt['Latent']:4d} "
              f"{cnt['Wrong_Result']:5d} {cnt['Timed_Out']:4d} {cnt['Exception']:4d}")

    reg_harmful = [
        (reg, cnt, sum(cnt[h] for h in HARMFUL))
        for reg, cnt in by_reg.items()
        if sum(cnt[h] for h in HARMFUL) > 0
    ]
    reg_harmful.sort(key=lambda x: (x[2], x[1]["_tot"]), reverse=True)
    if reg_harmful:
        print(f"\n  Top-{min(top_n, len(reg_harmful))} registros con fallos dañinos (estilo Fig. 5 Travessini):")
        print(f"    {'Registro':28s} {'Tot':>4s} {'Harm':>4s} {'Wrong':>5s} {'Tout':>4s} {'Exc':>4s}")
        for reg, cnt, harm in reg_harmful[:top_n]:
            print(f"    {reg:28s} {cnt['_tot']:4d} {harm:4d} {cnt['Wrong_Result']:5d} "
                  f"{cnt['Timed_Out']:4d} {cnt['Exception']:4d}")

    if show_failures:
        fails = [r for r in rows if r["outcome"] in HARMFUL]
        if fails:
            print("\n  Detalle de corridas dañinas:")
            for r in fails:
                print(f"    run={r['run_id']} {r['outcome']:12s} cause={r['trap_cause']} "
                      f"cyc={r['cycles']} inj={r['inj_regs']}[{r['inj_bits']}]@{r['inj_cycles']} ({r['inj_domains']})")


def analyze_file(csv_path: Path, top_n: int, show_failures: bool):
    rows = load_rows(csv_path)
    if not rows:
        print(f"=== {csv_path}: archivo vacío ===")
        return
    r0 = rows[0]
    k = int(r0["faults_per_run"])
    print(f"\n======================================================================")
    print(f"Archivo: {csv_path} | TMR={r0['tmr']} ECC={r0['ecc']} | {k}-SEU | N={len(rows)}")
    print(f"======================================================================")
    summarize_subset("Global (todo el SoC)", rows)

    # En 1-SEU reporta también el subconjunto excluyendo impactos en contadores de telemetría
    if k == 1:
        no_telem = [r for r in rows if r["inj_is_telem"] == "0"]
        if len(no_telem) != len(rows):
            summarize_subset("Sin contadores de telemetría", no_telem)

    print_profiling(rows, top_n, show_failures)


def main():
    ap = argparse.ArgumentParser(description="Analiza CSVs de campañas SEU de HPicoRV32")
    ap.add_argument("csv_files", nargs="+", type=Path)
    ap.add_argument("--top", type=int, default=15, help="Top-N registros vulnerables a mostrar")
    ap.add_argument("--show-failures", action="store_true", help="Lista cada corrida dañina")
    args = ap.parse_args()

    for p in args.csv_files:
        analyze_file(p, args.top, args.show_failures)


if __name__ == "__main__":
    main()